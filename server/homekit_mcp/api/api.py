"""
GraphQL API for HomeKit MCP.

Combined API with public endpoints (signup, login) and authenticated endpoints.
"""

import logging
from typing import List, Optional
from dataclasses import dataclass

from graphql_api import field

from homekit_mcp.models.db.database import get_session
from homekit_mcp.models.db.repositories import UserRepository, DeviceRepository
from homekit_mcp.auth import generate_token
from homekit_mcp.middleware import get_auth_context

logger = logging.getLogger(__name__)


# --- Response Types ---

@dataclass
class AuthResult:
    """Result of authentication operations."""
    success: bool
    token: Optional[str] = None
    error: Optional[str] = None
    user_id: Optional[str] = None
    email: Optional[str] = None


@dataclass
class UserInfo:
    """User account information."""
    id: str
    email: str
    name: Optional[str]
    created_at: str
    last_login_at: Optional[str]


@dataclass
class DeviceInfo:
    """Device information."""
    id: str
    device_id: str
    name: str
    status: str
    last_seen_at: Optional[str]
    home_count: int
    accessory_count: int


@dataclass
class DeviceRegistration:
    """Result of device registration."""
    success: bool
    device_id: Optional[str] = None
    error: Optional[str] = None


# --- API ---

class API:
    """HomeKit MCP GraphQL API."""

    # --- Public Endpoints (no auth required) ---

    @field(mutable=True)
    async def signup(
        self,
        email: str,
        password: str,
        name: Optional[str] = None
    ) -> AuthResult:
        """
        Create a new user account.

        Args:
            email: User's email address
            password: Password (min 8 characters)
            name: Optional display name

        Returns:
            AuthResult with token on success, error message on failure
        """
        if not email or "@" not in email:
            return AuthResult(success=False, error="Invalid email address")

        if not password or len(password) < 8:
            return AuthResult(success=False, error="Password must be at least 8 characters")

        try:
            with get_session() as session:
                user = UserRepository.create_user(
                    session=session,
                    email=email,
                    password=password,
                    name=name
                )

                token = generate_token(user.id, user.email)
                logger.info(f"User signed up: {user.email}")

                return AuthResult(
                    success=True,
                    token=token,
                    user_id=str(user.id),
                    email=user.email
                )

        except ValueError as e:
            return AuthResult(success=False, error=str(e))
        except Exception as e:
            logger.error(f"Signup error: {e}", exc_info=True)
            return AuthResult(success=False, error="An error occurred during signup")

    @field(mutable=True)
    async def login(
        self,
        email: str,
        password: str
    ) -> AuthResult:
        """
        Authenticate a user and return a token.

        Args:
            email: User's email address
            password: User's password

        Returns:
            AuthResult with token on success, error message on failure
        """
        if not email or not password:
            return AuthResult(success=False, error="Email and password are required")

        try:
            with get_session() as session:
                user = UserRepository.verify_password(
                    session=session,
                    email=email,
                    password=password
                )

                if not user:
                    return AuthResult(success=False, error="Invalid email or password")

                token = generate_token(user.id, user.email)
                logger.info(f"User logged in: {user.email}")

                return AuthResult(
                    success=True,
                    token=token,
                    user_id=str(user.id),
                    email=user.email
                )

        except Exception as e:
            logger.error(f"Login error: {e}", exc_info=True)
            return AuthResult(success=False, error="An error occurred during login")

    @field
    def health(self) -> str:
        """Health check endpoint."""
        return "ok"

    # --- Authenticated Endpoints ---

    @field
    async def me(self) -> Optional[UserInfo]:
        """Get current user's account information. Requires authentication."""
        auth = get_auth_context()
        if not auth:
            return None

        with get_session() as session:
            user = UserRepository.find_by_id(session, auth.user_id)
            if not user:
                return None

            return UserInfo(
                id=str(user.id),
                email=user.email,
                name=user.name,
                created_at=user.created_at.isoformat(),
                last_login_at=user.last_login_at.isoformat() if user.last_login_at else None
            )

    @field
    async def my_devices(self) -> List[DeviceInfo]:
        """Get all devices belonging to the current user. Requires authentication."""
        auth = get_auth_context()
        if not auth:
            return []

        with get_session() as session:
            devices = DeviceRepository.find_by_user(session, auth.user_id)

            return [
                DeviceInfo(
                    id=str(device.id),
                    device_id=device.device_id,
                    name=device.name,
                    status=device.status,
                    last_seen_at=device.last_seen_at.isoformat() if device.last_seen_at else None,
                    home_count=device.home_count,
                    accessory_count=device.accessory_count
                )
                for device in devices
            ]

    @field
    async def device(self, device_id: str) -> Optional[DeviceInfo]:
        """Get a specific device by device_id. Requires authentication."""
        auth = get_auth_context()
        if not auth:
            return None

        with get_session() as session:
            device = DeviceRepository.find_by_device_id(session, device_id)

            if not device or device.user_id != auth.user_id:
                return None

            return DeviceInfo(
                id=str(device.id),
                device_id=device.device_id,
                name=device.name,
                status=device.status,
                last_seen_at=device.last_seen_at.isoformat() if device.last_seen_at else None,
                home_count=device.home_count,
                accessory_count=device.accessory_count
            )

    @field(mutable=True)
    async def register_device(
        self,
        device_id: str,
        name: str
    ) -> DeviceRegistration:
        """
        Register a new device or update an existing one. Requires authentication.

        Args:
            device_id: Unique device identifier from the Mac app
            name: Display name for the device

        Returns:
            DeviceRegistration result
        """
        auth = get_auth_context()
        if not auth:
            return DeviceRegistration(success=False, error="Not authenticated")

        try:
            with get_session() as session:
                device = DeviceRepository.register_device(
                    session=session,
                    user_id=auth.user_id,
                    device_id=device_id,
                    name=name
                )

                logger.info(f"Device registered: {device_id} for user {auth.user_id}")

                return DeviceRegistration(
                    success=True,
                    device_id=device.device_id
                )

        except Exception as e:
            logger.error(f"Device registration error: {e}", exc_info=True)
            return DeviceRegistration(success=False, error="Failed to register device")

    @field(mutable=True)
    async def remove_device(self, device_id: str) -> bool:
        """Remove a device from the user's account. Requires authentication."""
        auth = get_auth_context()
        if not auth:
            return False

        with get_session() as session:
            device = DeviceRepository.find_by_device_id(session, device_id)

            if not device or device.user_id != auth.user_id:
                return False

            return DeviceRepository.delete(session, device)

    @field
    async def online_devices(self) -> List[DeviceInfo]:
        """Get all online devices belonging to the current user. Requires authentication."""
        auth = get_auth_context()
        if not auth:
            return []

        with get_session() as session:
            devices = DeviceRepository.get_online_devices(session, auth.user_id)

            return [
                DeviceInfo(
                    id=str(device.id),
                    device_id=device.device_id,
                    name=device.name,
                    status=device.status,
                    last_seen_at=device.last_seen_at.isoformat() if device.last_seen_at else None,
                    home_count=device.home_count,
                    accessory_count=device.accessory_count
                )
                for device in devices
            ]
