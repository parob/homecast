"""
Repository for User database operations.
"""

import uuid
import logging
import hashlib
import secrets
from datetime import datetime, timezone
from typing import Optional

from sqlmodel import Session, select

from homecast.models.db.models import User
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


class UserRepository(BaseRepository):
    """Repository for user operations."""

    MODEL_CLASS = User

    @classmethod
    def find_by_email(
        cls,
        session: Session,
        email: str
    ) -> Optional[User]:
        """Find a user by email address."""
        statement = select(User).where(User.email == email.lower())
        return session.exec(statement).one_or_none()

    @classmethod
    def create_user(
        cls,
        session: Session,
        email: str,
        password: str,
        name: Optional[str] = None
    ) -> User:
        """
        Create a new user with hashed password.

        Args:
            session: Database session
            email: User's email address
            password: Plain text password (will be hashed)
            name: Optional display name

        Returns:
            Created user

        Raises:
            ValueError: If email already exists
        """
        # Check if email already exists
        existing = cls.find_by_email(session, email)
        if existing:
            raise ValueError("Email already registered")

        # Hash password
        password_hash = cls._hash_password(password)

        user = User(
            email=email.lower(),
            password_hash=password_hash,
            name=name
        )

        return cls.create(session, user)

    @classmethod
    def verify_password(
        cls,
        session: Session,
        email: str,
        password: str
    ) -> Optional[User]:
        """
        Verify user credentials.

        Args:
            session: Database session
            email: User's email address
            password: Plain text password to verify

        Returns:
            User if credentials valid, None otherwise
        """
        user = cls.find_by_email(session, email)
        if not user:
            return None

        if not user.is_active:
            return None

        if not cls._verify_password(password, user.password_hash):
            return None

        # Update last login
        user.last_login_at = datetime.now(timezone.utc)
        cls.update(session, user)

        return user

    @classmethod
    def _hash_password(cls, password: str) -> str:
        """Hash a password with a random salt."""
        salt = secrets.token_hex(16)
        hash_obj = hashlib.pbkdf2_hmac(
            'sha256',
            password.encode('utf-8'),
            salt.encode('utf-8'),
            100000
        )
        return f"{salt}${hash_obj.hex()}"

    @classmethod
    def _verify_password(cls, password: str, password_hash: str) -> bool:
        """Verify a password against its hash."""
        try:
            salt, stored_hash = password_hash.split('$')
            hash_obj = hashlib.pbkdf2_hmac(
                'sha256',
                password.encode('utf-8'),
                salt.encode('utf-8'),
                100000
            )
            return hash_obj.hex() == stored_hash
        except (ValueError, AttributeError):
            return False

    @classmethod
    def update_password(
        cls,
        session: Session,
        user_id: uuid.UUID,
        new_password: str
    ) -> bool:
        """Update a user's password."""
        user = cls.find_by_id(session, user_id)
        if not user:
            return False

        user.password_hash = cls._hash_password(new_password)
        cls.update(session, user)
        return True

    @classmethod
    def get_settings(
        cls,
        session: Session,
        user_id: uuid.UUID
    ) -> Optional[str]:
        """Get user settings as JSON string."""
        user = cls.find_by_id(session, user_id)
        if not user:
            return None
        return user.settings_json

    @classmethod
    def update_settings(
        cls,
        session: Session,
        user_id: uuid.UUID,
        settings_json: str
    ) -> bool:
        """Update user settings."""
        user = cls.find_by_id(session, user_id)
        if not user:
            return False

        user.settings_json = settings_json
        cls.update(session, user)
        return True
