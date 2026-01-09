"""
Shared utilities for MCP endpoint handlers.

Provides common functionality for scoped MCP apps like /home/{id}/ and /homes/{id}/.
"""

import json
import logging
import re
from typing import Optional, Callable, Awaitable

from starlette.routing import get_route_path
from starlette.types import ASGIApp, Receive, Scope, Send

from homecast.auth import verify_token, extract_token_from_header
from homecast.middleware import _auth_context_var

logger = logging.getLogger(__name__)

# Regex to validate 8-character hex ID format
HEX_ID_PATTERN = re.compile(r'^[0-9a-f]{8}$', re.IGNORECASE)

# Regex to extract ID from path: {id}/... or /{id}/...
PATH_PATTERN = re.compile(r'^/?([^/]+)(/.*)?$')


def validate_hex_id(hex_id: str) -> Optional[str]:
    """
    Validate and normalize an 8-character hex ID.

    Returns:
        Normalized (lowercase) ID if valid, None otherwise
    """
    if not hex_id or not HEX_ID_PATTERN.match(hex_id):
        return None
    return hex_id.lower()


async def send_json_error(send: Send, status: int, message: str) -> None:
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


def extract_auth_from_scope(scope: Scope) -> tuple[Optional[str], Optional[dict]]:
    """
    Extract and verify auth token from request scope.

    Returns:
        (token, auth_context) tuple. Both None if no valid auth.
    """
    headers = dict(scope.get("headers", []))
    auth_header = headers.get(b"authorization", b"").decode()
    token = extract_token_from_header(auth_header)

    if not token:
        return None, None

    auth_context = verify_token(token)
    return token, auth_context


class ScopedMCPApp:
    """
    Base ASGI app for scoped MCP endpoints like /home/{id}/ or /homes/{id}/.

    Handles common functionality:
    - Path parsing and ID extraction
    - ID validation
    - Auth extraction
    - Error responses
    - Scope modification for child app

    Subclasses implement validate_and_setup() for specific logic.
    """

    def __init__(self, app: ASGIApp, id_name: str = "id"):
        self.app = app
        self.id_name = id_name  # e.g., "home_id" or "user_id"

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # Extract ID from path
        path = get_route_path(scope)
        match = PATH_PATTERN.match(path)
        if not match:
            await send_json_error(send, 404, "Not found")
            return

        raw_id = match.group(1)
        remaining_path = match.group(2) or "/"
        if not remaining_path.startswith("/"):
            remaining_path = "/" + remaining_path

        # Validate ID format
        validated_id = validate_hex_id(raw_id)
        if not validated_id:
            await send_json_error(send, 400, f"Invalid {self.id_name}: must be 8 hex characters, got '{raw_id}'")
            return

        # Let subclass do specific validation and setup
        result = await self.validate_and_setup(scope, send, validated_id)
        if result is None:
            return  # Error already sent

        auth_context, set_context, clear_context = result

        # Set auth context
        _auth_context_var.set(auth_context)

        try:
            # Create modified scope
            child_scope = dict(scope)
            child_scope["path"] = remaining_path
            child_scope["raw_path"] = remaining_path.encode()
            child_scope[self.id_name] = validated_id

            # Call child app (subclass can override for response wrapping)
            await self.call_app(child_scope, receive, send, validated_id)

        finally:
            clear_context()
            _auth_context_var.set(None)

    async def validate_and_setup(
        self,
        scope: Scope,
        send: Send,
        validated_id: str
    ) -> Optional[tuple[Optional[dict], Callable, Callable]]:
        """
        Validate the ID and set up context.

        Returns:
            (auth_context, set_context_func, clear_context_func) on success
            None if validation failed (error already sent)

        Subclasses must implement this.
        """
        raise NotImplementedError

    async def call_app(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
        validated_id: str
    ) -> None:
        """
        Call the wrapped app. Override for response interception.
        """
        await self.app(scope, receive, send)
