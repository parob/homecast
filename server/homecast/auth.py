"""
Authentication utilities for HomeCast.

Handles JWT token generation and verification.
"""

import uuid
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional
from dataclasses import dataclass

import jwt

from homecast import config

logger = logging.getLogger(__name__)


@dataclass
class AuthContext:
    """Authentication context for authenticated requests."""
    user_id: uuid.UUID
    email: str


def generate_token(user_id: uuid.UUID, email: str) -> str:
    """
    Generate a JWT token for a user.

    Args:
        user_id: User's UUID
        email: User's email address

    Returns:
        JWT token string
    """
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "email": email,
        "iat": now,
        "exp": now + timedelta(hours=config.JWT_EXPIRY_HOURS)
    }

    return jwt.encode(payload, config.JWT_SECRET, algorithm=config.JWT_ALGORITHM)


def verify_token(token: str) -> Optional[AuthContext]:
    """
    Verify a JWT token and extract the auth context.

    Args:
        token: JWT token string

    Returns:
        AuthContext if valid, None otherwise
    """
    try:
        payload = jwt.decode(
            token,
            config.JWT_SECRET,
            algorithms=[config.JWT_ALGORITHM]
        )

        user_id = uuid.UUID(payload["sub"])
        email = payload["email"]

        return AuthContext(user_id=user_id, email=email)

    except jwt.ExpiredSignatureError:
        logger.debug("Token expired")
        return None
    except jwt.InvalidTokenError as e:
        logger.debug(f"Invalid token: {e}")
        return None
    except (KeyError, ValueError) as e:
        logger.debug(f"Token payload error: {e}")
        return None


def extract_token_from_header(authorization: Optional[str]) -> Optional[str]:
    """
    Extract token from Authorization header.

    Args:
        authorization: Authorization header value (e.g., "Bearer <token>")

    Returns:
        Token string if valid format, None otherwise
    """
    if not authorization:
        return None

    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None

    return parts[1]
