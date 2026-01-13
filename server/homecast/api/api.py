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
from homecast.models.db.models import SessionType
from homecast.models.db.repositories import UserRepository, SessionRepository, CollectionRepository
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
    """Device/session information."""
    id: str
    device_id: Optional[str]
    name: Optional[str]
    session_type: str
    last_seen_at: Optional[str]


# --- HomeKit Types ---

@dataclass
class HomeKitCharacteristic:
    """A characteristic of a HomeKit service."""
    id: str
    characteristic_type: str
    is_readable: bool
    is_writable: bool
    value: Optional[str] = None  # JSON-encoded value (parse with JSON.parse on frontend)
    # Metadata from HomeKit (optional - only included when available)
    valid_values: Optional[List[int]] = None
    min_value: Optional[float] = None
    max_value: Optional[float] = None
    step_value: Optional[float] = None


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
class HomeKitZone:
    """A zone (group of rooms) in a HomeKit home."""
    id: str
    name: str
    room_ids: List[str]


@dataclass
class HomeKitServiceGroup:
    """A service group (grouped accessories) in a HomeKit home."""
    id: str
    name: str
    service_ids: List[str]
    accessory_ids: List[str]


@dataclass
class SetServiceGroupResult:
    """Result of setting a characteristic on a service group."""
    success: bool
    group_id: str
    characteristic_type: str
    affected_count: int
    value: Optional[str] = None  # JSON-encoded value


@dataclass
class SetCharacteristicResult:
    """Result of setting a characteristic."""
    success: bool
    accessory_id: str
    characteristic_type: str
    value: Optional[str] = None  # JSON-encoded value


@dataclass
class ExecuteSceneResult:
    """Result of executing a scene."""
    success: bool
    scene_id: str


@dataclass
class CharacteristicValue:
    """Result of reading a characteristic value."""
    accessory_id: str
    characteristic_type: str
    value: Optional[str] = None  # JSON-encoded value


@dataclass
class UserSettings:
    """User settings - stored as opaque JSON blob."""
    data: str = "{}"  # JSON string, frontend controls the schema


@dataclass
class UpdateSettingsResult:
    """Result of updating settings."""
    success: bool
    settings: Optional[UserSettings] = None


# --- Collection Types ---

@dataclass
class CollectionItem:
    """An item in a collection."""
    type: str  # "home" | "room" | "accessory"
    item_id: str


@dataclass
class CollectionInfo:
    """Collection information."""
    id: str
    name: str
    items: List["CollectionItem"]
    role: str
    is_shared: bool
    share_access_level: Optional[str]
    share_has_password: bool
    created_at: str


@dataclass
class CollectionResult:
    """Result of collection operations."""
    success: bool
    collection: Optional[CollectionInfo] = None
    error: Optional[str] = None


@dataclass
class ShareCollectionResult:
    """Result of sharing a collection."""
    success: bool
    share_url: Optional[str] = None
    error: Optional[str] = None


@dataclass
class PublicCollectionInfo:
    """Public collection info (before password verification)."""
    id: str
    name: str
    requires_password: bool
    access_level: Optional[str]  # null if password required


@dataclass
class CollectionItemsResult:
    """Result of fetching collection items."""
    success: bool
    items: Optional[List[CollectionItem]] = None
    access_level: Optional[str] = None
    error: Optional[str] = None


# --- Helper Functions ---

def parse_characteristic(data: dict) -> HomeKitCharacteristic:
    """Parse a characteristic dict into a typed object."""
    # JSON-encode the value so frontend can parse it with proper types
    raw_value = data.get("value")
    json_value = json.dumps(raw_value) if raw_value is not None else None

    # Extract metadata (optional fields from HomeKit)
    valid_values = data.get("validValues")
    min_value = data.get("minValue")
    max_value = data.get("maxValue")
    step_value = data.get("stepValue")

    return HomeKitCharacteristic(
        id=data.get("id", ""),
        characteristic_type=data.get("characteristicType", ""),
        is_readable=data.get("isReadable", False),
        is_writable=data.get("isWritable", False),
        value=json_value,
        valid_values=valid_values,
        min_value=min_value,
        max_value=max_value,
        step_value=step_value
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


def parse_zone(data: Any) -> HomeKitZone:
    """Parse a zone dict (or JSON string) into a typed object."""
    if isinstance(data, str):
        data = json.loads(data)

    return HomeKitZone(
        id=data.get("id", ""),
        name=data.get("name", ""),
        room_ids=data.get("roomIds", [])
    )


def parse_service_group(data: Any) -> HomeKitServiceGroup:
    """Parse a service group dict (or JSON string) into a typed object."""
    if isinstance(data, str):
        data = json.loads(data)

    return HomeKitServiceGroup(
        id=data.get("id", ""),
        name=data.get("name", ""),
        service_ids=data.get("serviceIds", []),
        accessory_ids=data.get("accessoryIds", [])
    )


# --- API ---

class HomecastAPI:
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
    async def settings(self) -> UserSettings:
        """Get current user's settings. Requires authentication."""
        auth = require_auth()

        with get_session() as session:
            settings_json = UserRepository.get_settings(session, auth.user_id)
            return UserSettings(data=settings_json or "{}")

    @field(mutable=True)
    async def update_settings(
        self,
        data: str,  # JSON blob - frontend controls the schema
    ) -> UpdateSettingsResult:
        """Update current user's settings. Requires authentication."""
        auth = require_auth()

        # Validate it's valid JSON
        try:
            json.loads(data)
        except json.JSONDecodeError:
            return UpdateSettingsResult(success=False)

        with get_session() as session:
            success = UserRepository.update_settings(session, auth.user_id, data)

            if success:
                return UpdateSettingsResult(
                    success=True,
                    settings=UserSettings(data=data)
                )
            else:
                return UpdateSettingsResult(success=False)

    @field
    async def devices(self) -> List[DeviceInfo]:
        """Get all active sessions for the current user. Requires authentication."""
        auth = require_auth()

        with get_session() as db:
            sessions = SessionRepository.get_user_sessions(db, auth.user_id)

            return [
                DeviceInfo(
                    id=str(s.id),
                    device_id=s.device_id,
                    name=s.name,
                    session_type=s.session_type,
                    last_seen_at=s.last_heartbeat.isoformat() if s.last_heartbeat else None
                )
                for s in sessions
            ]

    @field
    async def device(self, device_id: str) -> Optional[DeviceInfo]:
        """Get a specific device session by device_id. Requires authentication."""
        auth = require_auth()

        with get_session() as db:
            session = SessionRepository.get_device_session(db, device_id, include_stale=False)

            if not session or session.user_id != auth.user_id:
                return None

            return DeviceInfo(
                id=str(session.id),
                device_id=session.device_id,
                name=session.name,
                session_type=session.session_type,
                last_seen_at=session.last_heartbeat.isoformat() if session.last_heartbeat else None
            )

    @field(mutable=True)
    async def remove_device(self, device_id: str) -> bool:
        """Remove a device session. Requires authentication."""
        auth = require_auth()

        with get_session() as db:
            session = SessionRepository.get_device_session(db, device_id)

            if not session or session.user_id != auth.user_id:
                return False

            return SessionRepository.delete_by_device_id(db, device_id)

    # --- HomeKit Commands (via WebSocket to Mac app) ---

    @field
    async def homes(self) -> List[HomeKitHome]:
        """
        List all HomeKit homes from connected device.
        Requires authentication and a connected device.
        """
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
    async def characteristic_get(
        self,
        accessory_id: str,
        characteristic_type: str
    ) -> CharacteristicValue:
        """
        Read a characteristic value.

        Args:
            accessory_id: The accessory UUID
            characteristic_type: Type like "power-state", "brightness"

        Returns:
            CharacteristicValue with the current value (JSON-encoded)
        """
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="characteristic.get",
                payload={
                    "accessoryId": accessory_id,
                    "characteristicType": characteristic_type
                }
            )
            value = result.get("value")
            return CharacteristicValue(
                accessory_id=accessory_id,
                characteristic_type=characteristic_type,
                value=json.dumps(value) if value is not None else None
            )
        except Exception as e:
            logger.error(f"characteristic.get error: {e}")
            raise

    @field
    async def scenes(self, home_id: str) -> List[HomeKitScene]:
        """List scenes in a home."""
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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

    @field
    async def zones(self, home_id: str) -> List[HomeKitZone]:
        """List zones (room groups) in a home."""
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="zones.list",
                payload={"homeId": home_id}
            )
            return [parse_zone(z) for z in result.get("zones", [])]
        except Exception as e:
            logger.error(f"zones.list error: {e}")
            raise

    @field
    async def service_groups(self, home_id: str) -> List[HomeKitServiceGroup]:
        """List service groups (accessory groups) in a home."""
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            raise ValueError("No connected device")

        try:
            result = await route_request(
                device_id=device_id,
                action="serviceGroups.list",
                payload={"homeId": home_id}
            )
            return [parse_service_group(g) for g in result.get("serviceGroups", [])]
        except Exception as e:
            logger.error(f"serviceGroups.list error: {e}")
            raise

    @field(mutable=True)
    async def set_service_group(
        self,
        home_id: str,
        group_id: str,
        characteristic_type: str,
        value: str  # JSON-encoded value
    ) -> SetServiceGroupResult:
        """
        Set a characteristic on all accessories in a service group.

        Args:
            home_id: The home UUID
            group_id: The service group UUID
            characteristic_type: Type like "power_state", "brightness"
            value: JSON-encoded value (e.g., "true", "75")

        Returns:
            Result with success status and count of affected accessories
        """
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
                action="serviceGroup.set",
                payload={
                    "homeId": home_id,
                    "groupId": group_id,
                    "characteristicType": characteristic_type,
                    "value": parsed_value
                }
            )
            return SetServiceGroupResult(
                success=result.get("success", True),
                group_id=group_id,
                characteristic_type=characteristic_type,
                affected_count=result.get("affectedCount", 0),
                value=json.dumps(result.get("value", parsed_value))
            )
        except Exception as e:
            logger.error(f"serviceGroup.set error: {e}")
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
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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
                value=json.dumps(result.get("value", parsed_value))
            )
        except Exception as e:
            logger.error(f"characteristic.set error: {e}")
            raise

    @field(mutable=True)
    async def execute_scene(self, scene_id: str) -> ExecuteSceneResult:
        """Execute a scene."""
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

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

    # --- Collection Endpoints ---

    def _parse_collection_items(self, payload: str) -> List[CollectionItem]:
        """Parse collection payload JSON into CollectionItem list."""
        try:
            items = json.loads(payload)
            return [
                CollectionItem(type=item.get("type", ""), item_id=item.get("item_id", ""))
                for item in items
            ]
        except (json.JSONDecodeError, TypeError):
            return []

    def _build_collection_info(
        self,
        collection,
        access,
        public_shares: List = None
    ) -> CollectionInfo:
        """Build CollectionInfo from collection and access records."""
        is_shared = False
        share_access_level = None
        share_has_password = False

        if public_shares is None:
            public_shares = []

        if public_shares:
            is_shared = True
            # Find the first share without password, or use the first share
            for share in public_shares:
                if not share.passcode_hash:
                    share_access_level = share.role
                    break
            if share_access_level is None and public_shares:
                share_has_password = True

        return CollectionInfo(
            id=str(collection.id),
            name=collection.name,
            items=self._parse_collection_items(collection.payload),
            role=access.role,
            is_shared=is_shared,
            share_access_level=share_access_level,
            share_has_password=share_has_password,
            created_at=collection.created_at.isoformat()
        )

    @field
    async def collections(self) -> List[CollectionInfo]:
        """Get all collections for the current user. Requires authentication."""
        auth = require_auth()

        with get_session() as session:
            results = CollectionRepository.get_user_collections(session, auth.user_id)

            collections_info = []
            for collection, access in results:
                public_shares = CollectionRepository.get_public_shares(session, collection.id)
                collections_info.append(
                    self._build_collection_info(collection, access, public_shares)
                )

            return collections_info

    @field
    async def collection(self, collection_id: str) -> Optional[CollectionInfo]:
        """Get a specific collection. Requires authentication."""
        auth = require_auth()

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return None

        with get_session() as session:
            result = CollectionRepository.get_collection_with_access(session, cid, auth.user_id)
            if not result:
                return None

            collection, access = result
            public_shares = CollectionRepository.get_public_shares(session, collection.id)
            return self._build_collection_info(collection, access, public_shares)

    @field(mutable=True)
    async def create_collection(self, name: str) -> CollectionResult:
        """Create a new collection. Requires authentication."""
        auth = require_auth()

        if not name or not name.strip():
            return CollectionResult(success=False, error="Name is required")

        try:
            with get_session() as session:
                collection = CollectionRepository.create_collection(
                    session, name.strip(), auth.user_id
                )
                access_result = CollectionRepository.get_collection_with_access(
                    session, collection.id, auth.user_id
                )
                if access_result:
                    collection, access = access_result
                    return CollectionResult(
                        success=True,
                        collection=self._build_collection_info(collection, access, [])
                    )
                return CollectionResult(success=False, error="Failed to create collection")
        except Exception as e:
            logger.error(f"create_collection error: {e}")
            return CollectionResult(success=False, error="An error occurred")

    @field(mutable=True)
    async def update_collection(
        self,
        collection_id: str,
        name: Optional[str] = None,
        items: Optional[str] = None  # JSON string
    ) -> CollectionResult:
        """Update a collection (name and/or items). Requires authentication and owner role."""
        auth = require_auth()

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return CollectionResult(success=False, error="Invalid collection ID")

        # Validate items JSON if provided
        if items is not None:
            try:
                json.loads(items)
            except json.JSONDecodeError:
                return CollectionResult(success=False, error="Invalid items JSON")

        try:
            with get_session() as session:
                collection = CollectionRepository.update_collection(
                    session, cid, auth.user_id,
                    name=name.strip() if name else None,
                    payload=items
                )
                if not collection:
                    return CollectionResult(success=False, error="Collection not found or access denied")

                access_result = CollectionRepository.get_collection_with_access(
                    session, collection.id, auth.user_id
                )
                if access_result:
                    collection, access = access_result
                    public_shares = CollectionRepository.get_public_shares(session, collection.id)
                    return CollectionResult(
                        success=True,
                        collection=self._build_collection_info(collection, access, public_shares)
                    )
                return CollectionResult(success=False, error="Failed to update collection")
        except Exception as e:
            logger.error(f"update_collection error: {e}")
            return CollectionResult(success=False, error="An error occurred")

    @field(mutable=True)
    async def delete_collection(self, collection_id: str) -> bool:
        """Delete a collection. Requires authentication and owner role."""
        auth = require_auth()

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return False

        with get_session() as session:
            return CollectionRepository.delete_collection(session, cid, auth.user_id)

    @field(mutable=True)
    async def share_collection(
        self,
        collection_id: str,
        role: str = "view",
        passcode: Optional[str] = None,
        schedule: Optional[str] = None  # JSON string
    ) -> ShareCollectionResult:
        """Share a collection publicly. Requires authentication and owner role."""
        auth = require_auth()

        if role not in ("view", "control"):
            return ShareCollectionResult(success=False, error="Invalid role")

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return ShareCollectionResult(success=False, error="Invalid collection ID")

        # Validate schedule JSON if provided
        if schedule is not None:
            try:
                json.loads(schedule)
            except json.JSONDecodeError:
                return ShareCollectionResult(success=False, error="Invalid schedule JSON")

        try:
            with get_session() as session:
                share = CollectionRepository.create_public_share(
                    session, cid, auth.user_id,
                    role=role,
                    passcode=passcode,
                    schedule=schedule
                )
                if not share:
                    return ShareCollectionResult(success=False, error="Collection not found or access denied")

                # Generate share URL
                share_url = f"/c/{collection_id}"
                return ShareCollectionResult(success=True, share_url=share_url)
        except Exception as e:
            logger.error(f"share_collection error: {e}")
            return ShareCollectionResult(success=False, error="An error occurred")

    @field(mutable=True)
    async def unshare_collection(self, collection_id: str) -> bool:
        """Remove all public shares from a collection. Requires authentication and owner role."""
        auth = require_auth()

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return False

        with get_session() as session:
            return CollectionRepository.remove_all_public_shares(session, cid, auth.user_id)

    @field(mutable=True)
    async def save_shared_collection(self, collection_id: str) -> CollectionResult:
        """Save a shared collection to the current user's account. Requires authentication."""
        auth = require_auth()

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return CollectionResult(success=False, error="Invalid collection ID")

        with get_session() as session:
            access = CollectionRepository.save_collection_to_user(
                session, cid, auth.user_id, role="view"
            )
            if not access:
                return CollectionResult(success=False, error="Collection not found")

            result = CollectionRepository.get_collection_with_access(
                session, cid, auth.user_id
            )
            if result:
                collection, access = result
                public_shares = CollectionRepository.get_public_shares(session, collection.id)
                return CollectionResult(
                    success=True,
                    collection=self._build_collection_info(collection, access, public_shares)
                )
            return CollectionResult(success=False, error="Failed to save collection")

    # --- Public Collection Endpoints (no auth required) ---

    @field
    async def public_collection(self, collection_id: str) -> Optional[PublicCollectionInfo]:
        """Get public info about a collection (no auth required)."""
        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return None

        with get_session() as session:
            collection = CollectionRepository.get_collection_for_public(session, cid)
            if not collection:
                return None

            has_share, requires_password, access_level = \
                CollectionRepository.get_public_access_info(session, cid)

            if not has_share:
                return None

            return PublicCollectionInfo(
                id=str(collection.id),
                name=collection.name,
                requires_password=requires_password,
                access_level=access_level
            )

    @field
    async def public_collection_items(
        self,
        collection_id: str,
        passcode: Optional[str] = None
    ) -> CollectionItemsResult:
        """Get collection items (validates passcode and schedule if needed)."""
        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return CollectionItemsResult(success=False, error="Invalid collection ID")

        with get_session() as session:
            collection = CollectionRepository.get_collection_for_public(session, cid)
            if not collection:
                return CollectionItemsResult(success=False, error="Collection not found")

            access = CollectionRepository.verify_public_access(session, cid, passcode)
            if not access:
                # Check if collection is shared at all
                has_share, requires_password, _ = \
                    CollectionRepository.get_public_access_info(session, cid)
                if not has_share:
                    return CollectionItemsResult(success=False, error="Collection not found")
                if requires_password:
                    return CollectionItemsResult(success=False, error="Password required")
                return CollectionItemsResult(success=False, error="Access denied")

            # Check schedule
            allowed, error_msg = CollectionRepository.check_access_schedule(access)
            if not allowed:
                return CollectionItemsResult(success=False, error=error_msg)

            items = self._parse_collection_items(collection.payload)
            return CollectionItemsResult(
                success=True,
                items=items,
                access_level=access.role
            )

    @field(mutable=True)
    async def public_set_characteristic(
        self,
        collection_id: str,
        accessory_id: str,
        characteristic_type: str,
        value: str,  # JSON-encoded
        passcode: Optional[str] = None
    ) -> SetCharacteristicResult:
        """Set a characteristic value via a shared collection (validates access)."""
        from homecast.websocket.handler import route_request, get_user_device_id

        try:
            cid = __import__('uuid').UUID(collection_id)
        except ValueError:
            return SetCharacteristicResult(
                success=False,
                accessory_id=accessory_id,
                characteristic_type=characteristic_type
            )

        with get_session() as session:
            # Verify access
            access = CollectionRepository.verify_public_access(session, cid, passcode)
            if not access:
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

            # Check if role allows control
            if access.role != "control":
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

            # Check schedule
            allowed, _ = CollectionRepository.check_access_schedule(access)
            if not allowed:
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

            # Verify accessory is in collection
            collection = CollectionRepository.get_collection_for_public(session, cid)
            if not collection:
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

            items = self._parse_collection_items(collection.payload)
            accessory_ids = [item.item_id for item in items if item.type == "accessory"]
            if accessory_id not in accessory_ids:
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

            # Get owner's device
            owner_id = CollectionRepository.get_collection_owner_id(session, cid)
            if not owner_id:
                return SetCharacteristicResult(
                    success=False,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type
                )

        # Route request to owner's device
        device_id = await get_user_device_id(owner_id)
        if not device_id:
            raise ValueError("Owner's device not connected")

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
                value=json.dumps(result.get("value", parsed_value))
            )
        except Exception as e:
            logger.error(f"public_set_characteristic error: {e}")
            raise
