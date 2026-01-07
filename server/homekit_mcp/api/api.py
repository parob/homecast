"""
GraphQL API for HomeKit MCP.

Combined API with public endpoints (signup, login) and authenticated endpoints.
"""

import json
import logging
from typing import List, Optional, Any
from dataclasses import dataclass

from graphql_api import field


def parse_json_strings(items: List[Any]) -> List[dict]:
    """Parse any JSON strings in a list to dicts."""
    result = []
    for item in items:
        if isinstance(item, str):
            try:
                result.append(json.loads(item))
            except json.JSONDecodeError:
                result.append({"raw": item})
        elif isinstance(item, dict):
            result.append(item)
        else:
            result.append(item)
    return result

from homekit_mcp.models.db.database import get_session
from homekit_mcp.models.db.repositories import UserRepository, DeviceRepository
from homekit_mcp.auth import generate_token, AuthContext
from homekit_mcp.middleware import get_auth_context

logger = logging.getLogger(__name__)


class AuthenticationError(Exception):
    """Raised when authentication is required but not provided or invalid."""
    pass


def require_auth() -> AuthContext:
    """Get auth context or raise AuthenticationError."""
    auth = get_auth_context()
    if not auth:
        raise AuthenticationError("Authentication required")
    return auth


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
    async def me(self) -> UserInfo:
        """Get current user's account information. Requires authentication."""
        auth = require_auth()

        with get_session() as session:
            user = UserRepository.find_by_id(session, auth.user_id)
            if not user:
                raise AuthenticationError("User not found")

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
        auth = require_auth()

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
        auth = require_auth()

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
        auth = require_auth()

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
        auth = require_auth()

        with get_session() as session:
            device = DeviceRepository.find_by_device_id(session, device_id)

            if not device or device.user_id != auth.user_id:
                return False

            return DeviceRepository.delete(session, device)

    @field
    async def online_devices(self) -> List[DeviceInfo]:
        """Get all online devices belonging to the current user. Requires authentication."""
        auth = require_auth()

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

    # --- HomeKit Commands (via WebSocket to Mac app) ---

    @field
    async def homes(self) -> List[dict]:
        """
        List all HomeKit homes from connected device.
        Requires authentication and a connected device.
        """
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="homes.list",
                payload={}
            )
            return parse_json_strings(result.get("homes", []))
        except Exception as e:
            logger.error(f"homes.list error: {e}")
            raise

    @field
    async def rooms(self, home_id: str) -> List[dict]:
        """List rooms in a home. Requires authentication and connected device."""
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="rooms.list",
                payload={"homeId": home_id}
            )
            return parse_json_strings(result.get("rooms", []))
        except Exception as e:
            logger.error(f"rooms.list error: {e}")
            raise

    @field
    async def accessories(
        self,
        home_id: Optional[str] = None,
        room_id: Optional[str] = None
    ) -> List[dict]:
        """List accessories, optionally filtered by home or room."""
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        payload = {}
        if home_id:
            payload["homeId"] = home_id
        if room_id:
            payload["roomId"] = room_id

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="accessories.list",
                payload=payload
            )
            return parse_json_strings(result.get("accessories", []))
        except Exception as e:
            logger.error(f"accessories.list error: {e}")
            raise

    @field
    async def accessory(self, accessory_id: str) -> Optional[dict]:
        """Get a single accessory with full details."""
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="accessory.get",
                payload={"accessoryId": accessory_id}
            )
            accessory = result.get("accessory")
            if isinstance(accessory, str):
                return json.loads(accessory)
            return accessory
        except Exception as e:
            logger.error(f"accessory.get error: {e}")
            raise

    @field
    async def scenes(self, home_id: str) -> List[dict]:
        """List scenes in a home."""
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="scenes.list",
                payload={"homeId": home_id}
            )
            return parse_json_strings(result.get("scenes", []))
        except Exception as e:
            logger.error(f"scenes.list error: {e}")
            raise

    @field(mutable=True)
    async def set_characteristic(
        self,
        accessory_id: str,
        characteristic_type: str,
        value: str  # JSON-encoded value
    ) -> dict:
        """
        Set a characteristic value (control a device).

        Args:
            accessory_id: The accessory UUID
            characteristic_type: Type like "power-state", "brightness"
            value: JSON-encoded value (e.g., "true", "75", "\"hello\"")

        Returns:
            Result with success status
        """
        import json as json_module
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        # Parse the JSON value
        try:
            parsed_value = json_module.loads(value)
        except json_module.JSONDecodeError:
            raise ValueError(f"Invalid JSON value: {value}")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="characteristic.set",
                payload={
                    "accessoryId": accessory_id,
                    "characteristicType": characteristic_type,
                    "value": parsed_value
                }
            )
            return result
        except Exception as e:
            logger.error(f"characteristic.set error: {e}")
            raise

    @field(mutable=True)
    async def execute_scene(self, scene_id: str) -> dict:
        """Execute a scene."""
        from homekit_mcp.websocket.handler import connection_manager

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await connection_manager.send_request(
                device_id=device_id,
                action="scene.execute",
                payload={"sceneId": scene_id}
            )
            return result
        except Exception as e:
            logger.error(f"scene.execute error: {e}")
            raise
