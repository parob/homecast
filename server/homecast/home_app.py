"""
HomeAPI endpoint handler for HomeCast.

Provides a custom ASGI app that handles /home/{home_id}/ routing
and delegates to the HomeAPI via graphql-mcp.
"""

import json
import logging
from datetime import datetime, timezone
from typing import Optional, Callable

from starlette.types import Receive, Scope, Send
from graphql_mcp.server import GraphQLMCP
from graphql_api import GraphQLAPI

from homecast.mcp_base import ScopedMCPApp, send_json_error, extract_auth_from_scope
from homecast.api.home import HomeAPI, set_home_id, _room_key, _accessory_key, _group_key, _simplify_accessory, _unique_key
from homecast.models.db.database import get_session
from homecast.models.db.repositories import HomeRepository, UserRepository
from homecast.websocket.handler import route_request, get_user_device_id

logger = logging.getLogger(__name__)

# Placeholder for injecting home state into tool descriptions
STATE_PLACEHOLDER = "__HOMECAST_STATE__"


def get_home_auth_enabled(user_id, home_id_prefix: str, session) -> bool:
    """Check if auth is enabled for a specific home."""
    settings_json = UserRepository.get_settings(session, user_id)
    if not settings_json:
        return True

    try:
        settings = json.loads(settings_json)
        home_settings = settings.get("homes", {}).get(home_id_prefix, {})
        return home_settings.get("auth_enabled", True)
    except (json.JSONDecodeError, TypeError):
        return True


async def _fetch_home_state_summary(home_id_prefix: str) -> str:
    """Fetch home state and return a compact summary for injection into tool docs."""
    try:
        with get_session() as db:
            home = HomeRepository.get_by_prefix(db, home_id_prefix)
            if not home:
                return "(home not found)"

            device_id = await get_user_device_id(home.user_id)
            if not device_id:
                return "(device not connected)"

            full_home_id = str(home.home_id)
            home_key = _unique_key(home.name, full_home_id)

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

        accessory_by_id = {}
        for acc in accessories_result.get("accessories", []):
            acc_id = acc.get("id")
            if acc_id:
                accessory_by_id[acc_id] = acc

        state = {}
        for acc in accessories_result.get("accessories", []):
            room_key = _room_key(acc.get("roomName", "Unknown"), acc.get("roomId", ""))
            acc_key = _accessory_key(acc.get("name", "Unknown"), acc.get("id", ""))
            simplified = _simplify_accessory(acc)
            # Add fully qualified name: home.room.accessory
            simplified["name"] = f"{home_key}.{room_key}.{acc_key}"

            if room_key not in state:
                state[room_key] = {}
            state[room_key][acc_key] = simplified

        for group in groups_result.get("serviceGroups", []):
            group_id = group.get("id", "")
            grp_key = _group_key(group.get("name", "Unknown"), group_id)
            member_ids = group.get("accessoryIds", [])
            if member_ids:
                first_member = accessory_by_id.get(member_ids[0])
                if first_member:
                    room_key = _room_key(first_member.get("roomName", "Unknown"), first_member.get("roomId", ""))
                    if room_key not in state:
                        state[room_key] = {}

                    group_state = _simplify_accessory(first_member)
                    group_state["group"] = True
                    # Add fully qualified name for group: home.room.group
                    group_state["name"] = f"{home_key}.{room_key}.{grp_key}"

                    accessories_dict = {}
                    for acc_id in member_ids:
                        member = accessory_by_id.get(acc_id)
                        if member:
                            member_key = _accessory_key(member.get("name", "Unknown"), acc_id)
                            member_state = _simplify_accessory(member)
                            # Add fully qualified name for group member: home.room.group.accessory
                            member_state["name"] = f"{home_key}.{room_key}.{grp_key}.{member_key}"
                            accessories_dict[member_key] = member_state
                    group_state["accessories"] = accessories_dict

                    state[room_key][grp_key] = group_state

        fetched_at = datetime.now(timezone.utc).isoformat(timespec='seconds')
        state["_meta"] = {"fetched_at": fetched_at}

        return json.dumps(state, separators=(',', ':'))

    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        logger.warning(f"Failed to fetch home state for injection: {type(e).__name__}: {e} | {tb}")
        return "(state unavailable)"


# Create the MCP GraphQL API
_home_api = GraphQLAPI(root_type=HomeAPI)
_home_graphql_app = GraphQLMCP.from_api(api=_home_api, auth=None)
_home_http_app = _home_graphql_app.http_app(stateless_http=True)


class HomeScopedApp(ScopedMCPApp):
    """ASGI app that handles /home/{home_id}/ routing with state injection."""

    def __init__(self, app):
        super().__init__(app, id_name="home_id")

    async def validate_and_setup(
        self,
        scope: Scope,
        send: Send,
        home_id: str
    ) -> Optional[tuple[Optional[dict], Callable, Callable]]:
        """Validate home exists and check auth."""
        logger.info(f"HomeScopedApp: home_id={home_id}")

        with get_session() as session:
            home = HomeRepository.get_by_prefix(session, home_id)
            if not home:
                await send_json_error(send, 404, f"Unknown home: {home_id}")
                return None

            user_id = home.user_id
            auth_required = get_home_auth_enabled(user_id, home_id, session)

        auth_context = None
        if auth_required:
            token, auth_context = extract_auth_from_scope(scope)
            if not token:
                await send_json_error(send, 401, "Authentication required")
                return None
            if not auth_context:
                await send_json_error(send, 401, "Invalid or expired token")
                return None

        def set_context():
            set_home_id(home_id)

        def clear_context():
            set_home_id(None)

        set_context()
        return auth_context, set_context, clear_context

    async def call_app(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
        home_id: str
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

                    if STATE_PLACEHOLDER in body_str:
                        home_state = await _fetch_home_state_summary(home_id)
                        escaped_state = home_state.replace('\\', '\\\\').replace('"', '\\"')
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


# Create the home-scoped app wrapper
home_scoped_app = HomeScopedApp(_home_http_app)

# Export for lifespan integration
home_http_app = _home_http_app
