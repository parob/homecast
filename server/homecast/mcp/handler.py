"""
MCP endpoint handler for HomeCast.

Handles the /mcp/{home_id} route and sets up the MCP app for each request.
"""

import json
import logging
import re
from typing import Optional, List, Tuple

from starlette.requests import Request
from starlette.responses import Response, JSONResponse
from graphql_mcp.server import GraphQLMCP
from graphql_api import GraphQLAPI

from homecast.auth import verify_token, extract_token_from_header
from homecast.middleware import _auth_context_var
from homecast.mcp.api import MCPAPI
from homecast.mcp.context import set_mcp_home_id
from homecast.models.db.database import get_session
from homecast.models.db.repositories import HomeRepository, UserRepository

logger = logging.getLogger(__name__)

# Regex to validate home_id format (8 hex characters)
HOME_ID_PATTERN = re.compile(r'^[0-9a-f]{8}$', re.IGNORECASE)


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


# Create the MCP GraphQL API (reused for all requests)
_mcp_api = GraphQLAPI(root_type=MCPAPI)

# Create the MCP app once (reused for all requests)
_mcp_graphql_app = GraphQLMCP.from_api(api=_mcp_api, auth=None)
_mcp_http_app = _mcp_graphql_app.http_app(stateless_http=True)


async def mcp_endpoint(request: Request) -> Response:
    """
    MCP endpoint handler.

    Extracts home_id from path, validates it, checks auth requirements,
    and delegates to the graphql-mcp app.
    """
    # Extract home_id from path params
    home_id_raw = request.path_params.get("home_id", "")
    home_id = validate_home_id(home_id_raw)

    logger.info(f"MCP endpoint called: path={request.url.path}, home_id_raw='{home_id_raw}', validated='{home_id}'")

    if not home_id:
        return JSONResponse(
            {"error": f"Invalid home_id: must be 8 hex characters, got '{home_id_raw}'"},
            status_code=400
        )

    # Look up home to find owner and check auth settings
    with get_session() as session:
        logger.info(f"Looking up home with prefix: {home_id}")
        home = HomeRepository.get_by_prefix(session, home_id)
        logger.info(f"HomeRepository.get_by_prefix result: {home}")
        if not home:
            return JSONResponse(
                {"error": f"Unknown home: {home_id}"},
                status_code=404
            )

        user_id = home.user_id
        auth_required = get_home_auth_enabled(user_id, home_id, session)

    # Check authentication if required
    auth_context = None
    if auth_required:
        auth_header = request.headers.get("Authorization")
        token = extract_token_from_header(auth_header)

        if not token:
            return JSONResponse(
                {"error": "Authentication required"},
                status_code=401
            )

        auth_context = verify_token(token)
        if not auth_context:
            return JSONResponse(
                {"error": "Invalid or expired token"},
                status_code=401
            )

    # Set context vars for the request
    set_mcp_home_id(home_id)
    _auth_context_var.set(auth_context)

    try:
        # Call the MCP app using ASGI interface
        # We need to capture the response since it's an ASGI app
        response_started = False
        response_status = 200
        response_headers: List[Tuple[bytes, bytes]] = []
        response_body: List[bytes] = []

        async def receive():
            body = await request.body()
            logger.info(f"MCP receive called, body length: {len(body)}")
            return {"type": "http.request", "body": body, "more_body": False}

        async def send(message):
            nonlocal response_started, response_status, response_headers, response_body
            logger.info(f"MCP send called: type={message.get('type')}")
            if message["type"] == "http.response.start":
                response_started = True
                response_status = message["status"]
                response_headers = message.get("headers", [])
                logger.info(f"MCP response started: status={response_status}")
            elif message["type"] == "http.response.body":
                body = message.get("body", b"")
                if body:
                    response_body.append(body)
                    logger.info(f"MCP response body: {body[:500]}")  # First 500 bytes

        # Modify scope to set path to /mcp - GraphQLRootMiddleware routes /mcp to MCP handler
        mcp_scope = dict(request.scope)
        mcp_scope["path"] = "/mcp"
        mcp_scope["raw_path"] = b"/mcp"
        logger.info(f"Calling MCP app with modified scope path: {mcp_scope.get('path')} (original: {request.scope.get('path')})")
        await _mcp_http_app(mcp_scope, receive, send)
        logger.info(f"MCP app returned, status={response_status}")

        # Build and return the response
        headers = {
            key.decode() if isinstance(key, bytes) else key:
            value.decode() if isinstance(value, bytes) else value
            for key, value in response_headers
        }
        return Response(
            content=b"".join(response_body),
            status_code=response_status,
            headers=headers,
            media_type=headers.get("content-type", "application/json")
        )

    except Exception as e:
        logger.error(f"MCP endpoint error: {e}", exc_info=True)
        return JSONResponse(
            {"error": "Internal server error"},
            status_code=500
        )
    finally:
        # Clean up context
        set_mcp_home_id(None)
        _auth_context_var.set(None)
