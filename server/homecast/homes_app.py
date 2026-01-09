"""
HomesAPI endpoint handler for HomeCast.

Provides a custom ASGI app that handles /homes/{user_id}/ routing
and delegates to the HomesAPI via graphql-mcp.
"""

import json
import logging
from typing import Optional, Callable

from starlette.types import Scope, Send
from graphql_mcp.server import GraphQLMCP
from graphql_api import GraphQLAPI

from homecast.mcp_base import ScopedMCPApp, send_json_error, extract_auth_from_scope
from homecast.api.homes import HomesAPI, set_user_id
from homecast.models.db.database import get_session
from homecast.models.db.repositories import UserRepository

logger = logging.getLogger(__name__)


def get_homes_auth_enabled(user_id, session) -> bool:
    """Check if auth is enabled for the unified homes endpoint."""
    settings_json = UserRepository.get_settings(session, user_id)
    if not settings_json:
        return True  # Default to auth required

    try:
        settings = json.loads(settings_json)
        # homesAuthEnabled defaults to True if not set
        return settings.get("homesAuthEnabled", True)
    except (json.JSONDecodeError, TypeError):
        return True  # Default to auth required on parse error

# Create the MCP GraphQL API
_homes_api = GraphQLAPI(root_type=HomesAPI)
_homes_graphql_app = GraphQLMCP.from_api(api=_homes_api, auth=None)
_homes_http_app = _homes_graphql_app.http_app(stateless_http=True)


class HomesScopedApp(ScopedMCPApp):
    """ASGI app that handles /homes/{user_id}/ routing."""

    def __init__(self, app):
        super().__init__(app, id_name="user_id")

    async def validate_and_setup(
        self,
        scope: Scope,
        send: Send,
        user_id: str
    ) -> Optional[tuple[Optional[dict], Callable, Callable]]:
        """Validate user exists and verify auth if required."""
        logger.info(f"HomesScopedApp: user_id={user_id}")

        with get_session() as session:
            user = UserRepository.get_by_prefix(session, user_id)
            if not user:
                await send_json_error(send, 404, f"Unknown user: {user_id}")
                return None

            db_user_id = user.id
            auth_required = get_homes_auth_enabled(db_user_id, session)

        auth_context = None
        if auth_required:
            token, auth_context = extract_auth_from_scope(scope)
            if not token:
                await send_json_error(send, 401, "Authentication required")
                return None
            if not auth_context:
                await send_json_error(send, 401, "Invalid or expired token")
                return None

            # Verify token matches the requested user
            if auth_context.get("user_id") != str(db_user_id):
                await send_json_error(send, 403, "Access denied: token does not match user")
                return None

        def set_context():
            set_user_id(user_id)

        def clear_context():
            set_user_id(None)

        set_context()
        return auth_context, set_context, clear_context


# Create the homes-scoped app wrapper
homes_scoped_app = HomesScopedApp(_homes_http_app)

# Export for lifespan integration
homes_http_app = _homes_http_app
