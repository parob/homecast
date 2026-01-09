"""
HomesAPI endpoint handler for HomeCast.

Provides a custom ASGI app that handles /homes/{user_id}/ routing
and delegates to the HomesAPI via graphql-mcp.
"""

import json
import logging
from datetime import datetime, timezone
from typing import Optional, Callable, Dict, Any

from starlette.types import Scope, Send, Receive
from graphql_mcp.server import GraphQLMCP
from graphql_api import GraphQLAPI

from homecast.mcp_base import ScopedMCPApp, send_json_error, extract_auth_from_scope
from homecast.api.homes import HomesAPI, set_user_id, _get_user_homes
from homecast.api.home import _room_key, _accessory_key, _group_key, _simplify_accessory
from homecast.models.db.database import get_session
from homecast.models.db.repositories import UserRepository
from homecast.websocket.handler import route_request

logger = logging.getLogger(__name__)

# Placeholder for injecting homes state into tool descriptions
STATE_PLACEHOLDER = "__HOMECAST_HOMES_STATE__"


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


async def _fetch_all_homes_state_summary(user_id_prefix: str) -> str:
    """Fetch state for all homes and return a compact summary for injection into tool docs."""
    try:
        homes = await _get_user_homes(user_id_prefix)
        result: Dict[str, Any] = {}

        for home_info in homes:
            home_key = home_info["home_key"]
            device_id = home_info["device_id"]
            full_home_id = home_info["home_id"]

            if not device_id:
                continue  # Skip disconnected homes

            try:
                accessories_result = await route_request(
                    device_id=device_id,
                    action="accessories.list",
                    payload={"homeId": full_home_id, "includeValues": True}
                )

                groups_result = await route_request(
                    device_id=device_id,
                    action="serviceGroups.list",
                    payload={"homeId": full_home_id}
                )
            except Exception as e:
                logger.warning(f"Failed to fetch state for home {home_key}: {e}")
                continue

            # Build accessory lookup
            accessory_by_id: Dict[str, Dict[str, Any]] = {}
            for acc in accessories_result.get("accessories", []):
                acc_id = acc.get("id")
                if acc_id:
                    accessory_by_id[acc_id] = acc

            # Build room structure for this home
            home_state: Dict[str, Any] = {}

            for accessory in accessories_result.get("accessories", []):
                room_name = accessory.get("roomName", "Unknown")
                room_id = accessory.get("roomId", "")
                acc_name = accessory.get("name", "Unknown")

                room_key_str = _room_key(room_name, room_id)
                accessory_key_str = _accessory_key(acc_name, accessory.get("id", ""))
                simplified = _simplify_accessory(accessory)

                if room_key_str not in home_state:
                    home_state[room_key_str] = {}

                # Add fully qualified name: home.room.accessory
                simplified["name"] = f"{home_key}.{room_key_str}.{accessory_key_str}"
                home_state[room_key_str][accessory_key_str] = simplified

            # Add service groups
            for group in groups_result.get("serviceGroups", []):
                group_id = group.get("id", "")
                group_name = group.get("name", "Unknown")
                group_key_str = _group_key(group_name, group_id)
                member_ids = group.get("accessoryIds", [])

                if member_ids:
                    first_member = accessory_by_id.get(member_ids[0])
                    if first_member:
                        room_name = first_member.get("roomName", "Unknown")
                        room_id = first_member.get("roomId", "")
                        room_key_str = _room_key(room_name, room_id)

                        group_state = _simplify_accessory(first_member)
                        group_state["group"] = True
                        # Add fully qualified name for group: home.room.group
                        group_state["name"] = f"{home_key}.{room_key_str}.{group_key_str}"

                        if room_key_str not in home_state:
                            home_state[room_key_str] = {}

                        # Add member accessories
                        accessories_dict = {}
                        for acc_id in member_ids:
                            member = accessory_by_id.get(acc_id)
                            if member:
                                member_key = _accessory_key(member.get("name", "Unknown"), acc_id)
                                member_state = _simplify_accessory(member)
                                # Add fully qualified name for group member: home.room.group.accessory
                                member_state["name"] = f"{home_key}.{room_key_str}.{group_key_str}.{member_key}"
                                accessories_dict[member_key] = member_state
                        group_state["accessories"] = accessories_dict

                        home_state[room_key_str][group_key_str] = group_state

            if home_state:
                result[home_key] = home_state

        # Add metadata
        fetched_at = datetime.now(timezone.utc).isoformat(timespec='seconds')
        result["_meta"] = {"fetched_at": fetched_at}

        return json.dumps(result, separators=(',', ':'))

    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        logger.warning(f"Failed to fetch homes state for injection: {type(e).__name__}: {e} | {tb}")
        return "(state unavailable)"


# Create the MCP GraphQL API
_homes_api = GraphQLAPI(root_type=HomesAPI)
_homes_graphql_app = GraphQLMCP.from_api(api=_homes_api, auth=None)
_homes_http_app = _homes_graphql_app.http_app(stateless_http=True)


class HomesScopedApp(ScopedMCPApp):
    """ASGI app that handles /homes/{user_id}/ routing with state injection."""

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

    async def call_app(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
        user_id: str
    ) -> None:
        """Call app with response interception for state injection."""
        response_body = bytearray()
        original_headers = []

        async def wrapped_send(message):
            nonlocal response_body, original_headers

            if message["type"] == "http.response.start":
                original_headers = list(message.get("headers", []))
                return

            if message["type"] == "http.response.body":
                body = message.get("body", b"")
                response_body.extend(body)

                if not message.get("more_body", False):
                    body_str = bytes(response_body).decode("utf-8", errors="replace")

                    # Only fetch state if placeholder is present in response
                    if STATE_PLACEHOLDER in body_str:
                        homes_state = await _fetch_all_homes_state_summary(user_id)
                        # Escape for embedding in JSON string
                        escaped_state = homes_state.replace('\\', '\\\\').replace('"', '\\"')
                        body_str = body_str.replace(STATE_PLACEHOLDER, escaped_state)
                        response_body = bytearray(body_str.encode("utf-8"))

                    new_headers = []
                    for name, value in original_headers:
                        if name.lower() == b"content-length":
                            new_headers.append((b"content-length", str(len(response_body)).encode()))
                        else:
                            new_headers.append((name, value))

                    await send({
                        "type": "http.response.start",
                        "status": 200,
                        "headers": new_headers,
                    })
                    await send({
                        "type": "http.response.body",
                        "body": bytes(response_body),
                    })
                return

            await send(message)

        await self.app(scope, receive, wrapped_send)


# Create the homes-scoped app wrapper
homes_scoped_app = HomesScopedApp(_homes_http_app)

# Export for lifespan integration
homes_http_app = _homes_http_app
