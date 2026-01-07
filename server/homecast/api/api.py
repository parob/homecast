"""
GraphQL API for HomeCast.

Combined API with public endpoints (signup, login) and authenticated endpoints.
"""

import json
import logging
from typing import List, Optional, Any
from dataclasses import dataclass

from graphql_api import field

from homecast.models.db.database import get_session
from homecast.models.db.repositories import UserRepository, DeviceRepository
from homecast.auth import generate_token, AuthContext
from homecast.middleware import get_auth_context

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


# --- HomeKit Types ---

@dataclass
class HomeKitCharacteristic:
    """A characteristic of a HomeKit service."""
    id: str
    characteristic_type: str
    is_readable: bool
    is_writable: bool
    value: Optional[str] = None


@dataclass
class HomeKitService:
    """A service provided by a HomeKit accessory."""
    id: str
    name: str
    service_type: str
    characteristics: List["HomeKitCharacteristic"]


@dataclass
class HomeKitAccessory:
    """A HomeKit accessory (device)."""
    id: str
    name: str
    category: str
    is_reachable: bool
    services: List["HomeKitService"]
    room_id: Optional[str] = None
    room_name: Optional[str] = None


@dataclass
class HomeKitHome:
    """A HomeKit home."""
    id: str
    name: str
    is_primary: bool
    room_count: int
    accessory_count: int


@dataclass
class HomeKitRoom:
    """A room in a HomeKit home."""
    id: str
    name: str
    accessory_count: int


@dataclass
class HomeKitScene:
    """A HomeKit scene/action set."""
    id: str
    name: str
    action_count: int


@dataclass
class SetCharacteristicResult:
    """Result of setting a characteristic."""
    success: bool
    accessory_id: str
    characteristic_type: str
    value: Optional[str] = None


@dataclass
class ExecuteSceneResult:
    """Result of executing a scene."""
    success: bool
    scene_id: str


# --- Helper Functions ---

def parse_characteristic(data: dict) -> HomeKitCharacteristic:
    """Parse a characteristic dict into a typed object."""
    return HomeKitCharacteristic(
        id=data.get("id", ""),
        characteristic_type=data.get("characteristicType", ""),
        is_readable=data.get("isReadable", False),
        is_writable=data.get("isWritable", False),
        value=data.get("value")
    )


def parse_service(data: dict) -> HomeKitService:
    """Parse a service dict into a typed object."""
    characteristics = [
        parse_characteristic(c)
        for c in data.get("characteristics", [])
    ]
    return HomeKitService(
        id=data.get("id", ""),
        name=data.get("name", ""),
        service_type=data.get("serviceType", ""),
        characteristics=characteristics
    )


def parse_accessory(data: Any) -> HomeKitAccessory:
    """Parse an accessory dict (or JSON string) into a typed object."""
    # Handle JSON strings from Mac app
    if isinstance(data, str):
        data = json.loads(data)

    services = [
        parse_service(s)
        for s in data.get("services", [])
    ]
    return HomeKitAccessory(
        id=data.get("id", ""),
        name=data.get("name", ""),
        category=data.get("category", ""),
        is_reachable=data.get("isReachable", False),
        services=services,
        room_id=data.get("roomId"),
        room_name=data.get("roomName")
    )


def parse_home(data: Any) -> HomeKitHome:
    """Parse a home dict (or JSON string) into a typed object."""
    if isinstance(data, str):
        data = json.loads(data)

    return HomeKitHome(
        id=data.get("id", ""),
        name=data.get("name", ""),
        is_primary=data.get("isPrimary", False),
        room_count=data.get("roomCount", 0),
        accessory_count=data.get("accessoryCount", 0)
    )


def parse_room(data: Any) -> HomeKitRoom:
    """Parse a room dict (or JSON string) into a typed object."""
    if isinstance(data, str):
        data = json.loads(data)

    return HomeKitRoom(
        id=data.get("id", ""),
        name=data.get("name", ""),
        accessory_count=data.get("accessoryCount", 0)
    )


def parse_scene(data: Any) -> HomeKitScene:
    """Parse a scene dict (or JSON string) into a typed object."""
    if isinstance(data, str):
        data = json.loads(data)

    return HomeKitScene(
        id=data.get("id", ""),
        name=data.get("name", ""),
        action_count=data.get("actionCount", 0)
    )


# --- API ---

class API:
    """HomeCast GraphQL API."""

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
    async def homes(self) -> List[HomeKitHome]:
        """
        List all HomeKit homes from connected device.
        Requires authentication and a connected device.
        """
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="homes.list",
                payload={}
            )
            return [parse_home(h) for h in result.get("homes", [])]
        except Exception as e:
            logger.error(f"homes.list error: {e}")
            raise

    @field
    async def rooms(self, home_id: str) -> List[HomeKitRoom]:
        """List rooms in a home. Requires authentication and connected device."""
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="rooms.list",
                payload={"homeId": home_id}
            )
            return [parse_room(r) for r in result.get("rooms", [])]
        except Exception as e:
            logger.error(f"rooms.list error: {e}")
            raise

    @field
    async def accessories(
        self,
        home_id: Optional[str] = None,
        room_id: Optional[str] = None
    ) -> List[HomeKitAccessory]:
        """List accessories, optionally filtered by home or room."""
        from homecast.websocket.handler import route_request

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
            result = await route_request(
                device_id=device_id,
                action="accessories.list",
                payload=payload
            )
            return [parse_accessory(a) for a in result.get("accessories", [])]
        except Exception as e:
            logger.error(f"accessories.list error: {e}")
            raise

    @field
    async def accessory(self, accessory_id: str) -> Optional[HomeKitAccessory]:
        """Get a single accessory with full details."""
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="accessory.get",
                payload={"accessoryId": accessory_id}
            )
            accessory_data = result.get("accessory")
            if accessory_data:
                return parse_accessory(accessory_data)
            return None
        except Exception as e:
            logger.error(f"accessory.get error: {e}")
            raise

    @field
    async def scenes(self, home_id: str) -> List[HomeKitScene]:
        """List scenes in a home."""
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="scenes.list",
                payload={"homeId": home_id}
            )
            return [parse_scene(s) for s in result.get("scenes", [])]
        except Exception as e:
            logger.error(f"scenes.list error: {e}")
            raise

    @field(mutable=True)
    async def set_characteristic(
        self,
        accessory_id: str,
        characteristic_type: str,
        value: str  # JSON-encoded value
    ) -> SetCharacteristicResult:
        """
        Set a characteristic value (control a device).

        Args:
            accessory_id: The accessory UUID
            characteristic_type: Type like "power-state", "brightness"
            value: JSON-encoded value (e.g., "true", "75", "\"hello\"")

        Returns:
            Result with success status
        """
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        # Parse the JSON value
        try:
            parsed_value = json.loads(value)
        except json.JSONDecodeError:
            raise ValueError(f"Invalid JSON value: {value}")

        try:
            result = await route_request(
                device_id=device_id,
                action="characteristic.set",
                payload={
                    "accessoryId": accessory_id,
                    "characteristicType": characteristic_type,
                    "value": parsed_value
                }
            )
            return SetCharacteristicResult(
                success=result.get("success", True),
                accessory_id=accessory_id,
                characteristic_type=characteristic_type,
                value=str(result.get("value", parsed_value))
            )
        except Exception as e:
            logger.error(f"characteristic.set error: {e}")
            raise

    @field(mutable=True)
    async def execute_scene(self, scene_id: str) -> ExecuteSceneResult:
        """Execute a scene."""
        from homecast.websocket.handler import route_request

        auth = require_auth()
        device_id = await connection_manager.get_user_device(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="scene.execute",
                payload={"sceneId": scene_id}
            )
            return ExecuteSceneResult(
                success=result.get("success", True),
                scene_id=scene_id
            )
        except Exception as e:
            logger.error(f"scene.execute error: {e}")
            raise
