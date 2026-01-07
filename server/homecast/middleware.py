"""
Middleware for HomeCast.

Handles CORS, request context, and authentication.
"""

import logging
from contextvars import ContextVar
from typing import Optional

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

from homecast.auth import AuthContext, verify_token, extract_token_from_header

logger = logging.getLogger(__name__)

# Context variables for request-scoped data
_request_var: ContextVar[Optional[Request]] = ContextVar("request", default=None)
_auth_context_var: ContextVar[Optional[AuthContext]] = ContextVar("auth_context", default=None)


def get_request() -> Optional[Request]:
    """Get the current request from context."""
    return _request_var.get()


def get_auth_context() -> Optional[AuthContext]:
    """Get the current auth context from context."""
    return _auth_context_var.get()


class RequestContextMiddleware(BaseHTTPMiddleware):
    """Store request in context for access in resolvers."""

    async def dispatch(self, request: Request, call_next) -> Response:
        _request_var.set(request)

        # Extract and verify auth token
        auth_header = request.headers.get("Authorization")
        token = extract_token_from_header(auth_header)

        if token:
            auth_context = verify_token(token)
            _auth_context_var.set(auth_context)
        else:
            _auth_context_var.set(None)

        try:
            response = await call_next(request)
            return response
        finally:
            _request_var.set(None)
            _auth_context_var.set(None)


class CORSMiddleware(BaseHTTPMiddleware):
    """Handle CORS for all requests."""

    def __init__(self, app, allowed_origins: list[str]):
        super().__init__(app)
        self.allowed_origins = allowed_origins

    async def dispatch(self, request: Request, call_next) -> Response:
        origin = request.headers.get("origin", "")

        # Handle preflight requests
        if request.method == "OPTIONS":
            response = Response(status_code=204)
        else:
            response = await call_next(request)

        # Set CORS headers
        if origin in self.allowed_origins or "*" in self.allowed_origins:
            response.headers["Access-Control-Allow-Origin"] = origin
        elif self.allowed_origins:
            response.headers["Access-Control-Allow-Origin"] = self.allowed_origins[0]

        response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
        response.headers["Access-Control-Allow-Credentials"] = "true"
        response.headers["Access-Control-Max-Age"] = "86400"

        return response


class AuthRequiredMiddleware(BaseHTTPMiddleware):
    """Require authentication for requests."""

    async def dispatch(self, request: Request, call_next) -> Response:
        auth = get_auth_context()

        if not auth:
            return Response(
                content='{"error": "Authentication required"}',
                status_code=401,
                media_type="application/json"
            )

        return await call_next(request)
