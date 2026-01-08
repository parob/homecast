"""
HomeAPI endpoint handler for HomeCast.

Provides a custom ASGI app that handles /home/{home_id}/ routing
and delegates to the HomeAPI via graphql-mcp.
"""

import json
import logging
import re
from typing import Optional

from starlette.routing import get_route_path
from starlette.types import ASGIApp, Receive, Scope, Send
from graphql_mcp.server import GraphQLMCP
from graphql_api import GraphQLAPI

from homecast.auth import verify_token, extract_token_from_header
from homecast.middleware import _auth_context_var
from homecast.api.home import HomeAPI, set_home_id, _sanitize_name, _simplify_accessory
from homecast.models.db.database import get_session
from homecast.models.db.repositories import HomeRepository, UserRepository
from homecast.websocket.handler import route_request, get_user_device_id

logger = logging.getLogger(__name__)

# Regex to validate home_id format (8 hex characters)
HOME_ID_PATTERN = re.compile(r'^[0-9a-f]{8}$', re.IGNORECASE)

# Placeholder for injecting home state into tool descriptions
STATE_PLACEHOLDER = "__HOMECAST_STATE__"
# Regex to extract home_id from path: {home_id}/... or /{home_id}/... (Mount strips /home/ prefix)
HOME_PATH_PATTERN = re.compile(r'^/?([^/]+)(/.*)?$')


def validate_home_id(home_id: str) -> Optional[str]:
    """
    Validate and normalize home_id.

    Args:
        home_id: The home_id from URL path

    Returns:
        Normalized (lowercase) home_id if valid, None otherwise
    """
    if not home_id or not HOME_ID_PATTERN.match(home_id):
        return None
    return home_id.lower()


def get_home_auth_enabled(user_id, home_id_prefix: str, session) -> bool:
    """
    Check if auth is enabled for a specific home.

    Args:
        user_id: User UUID
        home_id_prefix: First 8 chars of home ID (lowercase)
        session: Database session

    Returns:
        True if auth is required (default), False if unauthenticated access allowed
    """
    settings_json = UserRepository.get_settings(session, user_id)
    if not settings_json:
        return True  # Default to auth required

    try:
        settings = json.loads(settings_json)
        home_settings = settings.get("homes", {}).get(home_id_prefix, {})
        return home_settings.get("auth_enabled", True)
    except (json.JSONDecodeError, TypeError):
        return True  # Default to auth required on parse error


async def _fetch_home_state_summary(home_id_prefix: str) -> str:
    """
    Fetch home state and return a compact summary for injection into tool docs.

    Returns a JSON string with rooms, accessories, and groups.
    """
    try:
        with get_session() as db:
            home = HomeRepository.get_by_prefix(db, home_id_prefix)
            if not home:
                return "(home not found)"

            device_id = await get_user_device_id(home.user_id)
            if not device_id:
                return "(device not connected)"

            full_home_id = str(home.home_id)

        # Fetch accessories
        accessories_result = await route_request(
            device_id=device_id,
            action="accessories.list",
            payload={"homeId": full_home_id, "includeValues": True}
        )

        # Fetch service groups
        groups_result = await route_request(
            device_id=device_id,
            action="serviceGroups.list",
            payload={"homeId": full_home_id}
        )

        # Build accessory lookup by ID
        accessory_by_id = {}
        for acc in accessories_result.get("accessories", []):
            acc_id = acc.get("id")
            if acc_id:
                accessory_by_id[acc_id] = acc

        # Build compact room summary
        state = {}
        for acc in accessories_result.get("accessories", []):
            room = _sanitize_name(acc.get("roomName", "Unknown"))
            name = _sanitize_name(acc.get("name", "Unknown"))
            simplified = _simplify_accessory(acc)

            if room not in state:
                state[room] = {}
            state[room][name] = simplified

        # Add service groups in the room of their first member
        for group in groups_result.get("serviceGroups", []):
            group_name = _sanitize_name(group.get("name", "Unknown"))
            member_ids = group.get("accessoryIds", [])
            if member_ids:
                first_member = accessory_by_id.get(member_ids[0])
                if first_member:
                    room_name = first_member.get("roomName", "Unknown")
                    room_key = _sanitize_name(room_name)
                    if room_key not in state:
                        state[room_key] = {}
                    group_state = _simplify_accessory(first_member)
                    state[room_key][group_name] = group_state

        # Format as compact JSON
        return json.dumps(state, separators=(',', ':'))

    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        logger.warning(f"Failed to fetch home state for injection: {type(e).__name__}: {e} | {tb}")
        return "(state unavailable)"


# Create the MCP GraphQL API (reused for all requests)
_home_api = GraphQLAPI(root_type=HomeAPI)

# Create the MCP app once (reused for all requests)
_home_graphql_app = GraphQLMCP.from_api(api=_home_api, auth=None)
_home_http_app = _home_graphql_app.http_app(stateless_http=True)


class HomeScopedApp:
    """
    ASGI app that handles /home/{home_id}/ routing.

    This app:
    1. Extracts home_id from the path
    2. Validates the home exists and checks auth settings
    3. Sets up context vars for the home_id
    4. Strips the /home/{home_id} prefix and delegates to the MCP app

    Similar to how Starlette's Mount works, but with dynamic home_id extraction.
    """

    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # Use get_route_path to get path relative to mount point
        path = get_route_path(scope)

        # Extract home_id from path
        match = HOME_PATH_PATTERN.match(path)
        if not match:
            await self._send_error(send, 404, "Not found")
            return

        home_id_raw = match.group(1)
        remaining_path = match.group(2) or "/"
        # Ensure remaining_path starts with /
        if not remaining_path.startswith("/"):
            remaining_path = "/" + remaining_path

        # Validate home_id format
        home_id = validate_home_id(home_id_raw)
        if not home_id:
            await self._send_error(send, 400, f"Invalid home_id: must be 8 hex characters, got '{home_id_raw}'")
            return

        logger.info(f"HomeScopedApp: path={path}, home_id={home_id}, remaining_path={remaining_path}")

        # Look up home to find owner and check auth settings
        with get_session() as session:
            home = HomeRepository.get_by_prefix(session, home_id)
            if not home:
                await self._send_error(send, 404, f"Unknown home: {home_id}")
                return

            user_id = home.user_id
            auth_required = get_home_auth_enabled(user_id, home_id, session)

        # Check authentication if required
        auth_context = None
        if auth_required:
            # Extract auth header from scope
            headers = dict(scope.get("headers", []))
            auth_header = headers.get(b"authorization", b"").decode()
            token = extract_token_from_header(auth_header)

            if not token:
                await self._send_error(send, 401, "Authentication required")
                return

            auth_context = verify_token(token)
            if not auth_context:
                await self._send_error(send, 401, "Invalid or expired token")
                return

        # Set context vars for the request
        set_home_id(home_id)
        _auth_context_var.set(auth_context)

        try:
            # Create modified scope with path stripped of /home/{home_id} prefix
            child_scope = dict(scope)
            child_scope["path"] = remaining_path
            child_scope["raw_path"] = remaining_path.encode()
            child_scope["home_id"] = home_id

            logger.debug(f"Delegating to MCP app with path: {remaining_path}")

            # Wrap send to inject state into response (only if placeholder present)
            response_started = False
            response_body = bytearray()
            original_headers = []

            async def wrapped_send(message):
                nonlocal response_started, response_body, original_headers

                if message["type"] == "http.response.start":
                    response_started = True
                    original_headers = list(message.get("headers", []))
                    # Don't send yet - buffer until we have body
                    return

                if message["type"] == "http.response.body":
                    body = message.get("body", b"")
                    response_body.extend(body)

                    # If more_body is False or not present, we have the full response
                    if not message.get("more_body", False):
                        body_str = bytes(response_body).decode("utf-8", errors="replace")

                        # Only fetch state if placeholder is present in response
                        if STATE_PLACEHOLDER in body_str:
                            home_state = await _fetch_home_state_summary(home_id)
                            # Escape for embedding in JSON string (escape quotes and backslashes)
                            escaped_state = home_state.replace('\\', '\\\\').replace('"', '\\"')
                            body_str = body_str.replace(STATE_PLACEHOLDER, escaped_state)
                            response_body = bytearray(body_str.encode("utf-8"))

                        # Update content-length header
                        new_headers = []
                        for name, value in original_headers:
                            if name.lower() == b"content-length":
                                new_headers.append((b"content-length", str(len(response_body)).encode()))
                            else:
                                new_headers.append((name, value))

                        # Send the modified response
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

                # Pass through other message types
                await send(message)

            await self.app(child_scope, receive, wrapped_send)

        finally:
            # Clean up context
            set_home_id(None)
            _auth_context_var.set(None)

    async def _send_error(self, send: Send, status: int, message: str) -> None:
        """Send a JSON error response."""
        body = json.dumps({"error": message}).encode()
        await send({
            "type": "http.response.start",
            "status": status,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode()),
            ],
        })
        await send({
            "type": "http.response.body",
            "body": body,
        })


# Create the home-scoped app wrapper
home_scoped_app = HomeScopedApp(_home_http_app)

# Export for lifespan integration
home_http_app = _home_http_app
