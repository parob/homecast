"""
GraphQL API for HomeCast.

Combined API with public endpoints (signup, login) and authenticated endpoints.
"""

import json
import logging
from typing import List, Optional, Any
from dataclasses import dataclass

from graphql import GraphQLError
from graphql_api import field

from homecast.models.db.database import get_session
from homecast.models.db.models import SessionType, EntityAccess, StoredEntity
from homecast.models.db.repositories import UserRepository, SessionRepository, EntityAccessRepository, StoredEntityRepository
from homecast.auth import generate_token, AuthContext
from homecast.middleware import get_auth_context
from homecast.utils.share_hash import encode_share_hash, decode_share_hash

logger = logging.getLogger(__name__)


class AuthenticationError(Exception):
    """Raised when authentication is required but not provided or invalid."""
    pass


def require_auth() -> AuthContext:
    """Get auth context or raise GraphQLError."""
    auth = get_auth_context()
    if not auth:
        raise GraphQLError("Authentication required. Please sign in.")
    return auth


def require_admin() -> AuthContext:
    """Get auth context or raise GraphQLError if not admin."""
    from homecast.models.db.models import User
    auth = require_auth()
    with get_session() as session:
        user = session.get(User, auth.user_id)
        if not user or not user.is_admin:
            raise GraphQLError("Admin access required")
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
    is_admin: bool = False


@dataclass
class DeviceInfo:
    """Device/session information."""
    id: str
    device_id: Optional[str]
    name: Optional[str]
    session_type: str
    last_seen_at: Optional[str]


@dataclass
class ConnectionDebugInfo:
    """Debug information about server connection and routing."""
    server_instance_id: str
    pubsub_enabled: bool
    pubsub_slot: Optional[str]
    device_connected: bool
    device_id: Optional[str]
    device_instance_id: Optional[str]
    routing_mode: str  # "local", "pubsub", or "not_connected"


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
    home_id: Optional[str] = None
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


# --- Stored Entity Types ---

@dataclass
class StoredEntityInfo:
    """Stored entity information for GraphQL responses."""
    id: str
    entity_type: str
    entity_id: str
    parent_id: Optional[str]
    data_json: str
    layout_json: str
    updated_at: str


@dataclass
class SyncEntitiesResult:
    """Result of syncing entities."""
    success: bool
    synced_count: int


@dataclass
class UpdateEntityLayoutResult:
    """Result of updating entity layout."""
    success: bool
    entity: Optional[StoredEntityInfo] = None


# --- Collection Types ---

@dataclass
class Collection:
    """Collection information for GraphQL responses.

    Collections are now stored in StoredEntity table with entity_type='collection'.
    This dataclass provides backward-compatible API responses.
    """
    id: str
    name: str
    payload: str  # JSON string: {"groups": [...], "items": [...]}
    created_at: str
    settings_json: Optional[str] = None  # JSON string for display settings


# --- Entity Access Types ---

@dataclass
class EntityAccessInfo:
    """Entity access configuration for GraphQL responses."""
    id: str
    entity_type: str
    entity_id: str
    access_type: str  # "public", "passcode", "user"
    role: str  # "view", "control"
    name: Optional[str] = None  # Label for passcode
    user_id: Optional[str] = None  # For user access
    user_email: Optional[str] = None  # Resolved email for user access
    has_passcode: bool = False  # True if passcode is set
    access_schedule: Optional[str] = None
    created_at: Optional[str] = None


@dataclass
class SharingInfo:
    """Summary of sharing configuration for an entity."""
    is_shared: bool
    has_public: bool
    public_role: Optional[str]  # "view" or "control" if public
    passcode_count: int
    user_count: int
    share_hash: str  # The hash for the share URL
    share_url: str  # Full URL: https://homecast.cloud/s/{hash}


@dataclass
class SharedEntityData:
    """Data returned for a shared entity."""
    entity_type: str
    entity_id: str
    entity_name: str
    role: str  # "view" or "control"
    requires_passcode: bool  # True if passcode required for this access level
    can_upgrade_with_passcode: bool = False  # True if a passcode exists that grants higher access
    # Entity-specific data (JSON string)
    data: Optional[str] = None


@dataclass
class CreateEntityAccessResult:
    """Result of creating entity access."""
    success: bool
    access: Optional[EntityAccessInfo] = None
    error: Optional[str] = None


@dataclass
class DeleteEntityAccessResult:
    """Result of deleting entity access."""
    success: bool
    error: Optional[str] = None


# --- Admin Types ---

@dataclass
class AdminUserSummary:
    """Summary of a user for admin user list."""
    id: str
    email: str
    name: Optional[str]
    created_at: str
    last_login_at: Optional[str]
    is_active: bool
    is_admin: bool
    device_count: int
    home_count: int


@dataclass
class AdminUsersResult:
    """Result of admin user list query."""
    users: List[AdminUserSummary]
    total_count: int
    has_more: bool


@dataclass
class AdminDeviceInfo:
    """Device info for admin panel."""
    id: str
    device_id: Optional[str]
    name: Optional[str]
    session_type: str
    last_seen_at: Optional[str]


@dataclass
class AdminHomeInfo:
    """Home info for admin panel."""
    id: str
    name: str


@dataclass
class AdminUserDetail:
    """Detailed user information for admin panel."""
    id: str
    email: str
    name: Optional[str]
    created_at: str
    last_login_at: Optional[str]
    is_active: bool
    is_admin: bool
    devices: List[AdminDeviceInfo]
    homes: List[AdminHomeInfo]
    settings_json: Optional[str]


@dataclass
class AdminLogEntry:
    """System log entry for admin panel."""
    id: str
    timestamp: str
    level: str
    source: str
    message: str
    user_id: Optional[str]
    user_email: Optional[str]
    device_id: Optional[str]
    trace_id: Optional[str]
    span_name: Optional[str]
    action: Optional[str]
    accessory_id: Optional[str]
    accessory_name: Optional[str]
    success: Optional[bool]
    error: Optional[str]
    latency_ms: Optional[int]
    metadata: Optional[str]


@dataclass
class AdminLogsResult:
    """Result of admin logs query."""
    logs: List[AdminLogEntry]
    total_count: int


@dataclass
class AdminServerInstance:
    """Server instance info for admin panel."""
    instance_id: str
    slot_name: Optional[str]
    last_heartbeat: Optional[str]


@dataclass
class AdminSystemDiagnostics:
    """System-wide diagnostics for admin panel."""
    server_instances: List[AdminServerInstance]
    pubsub_enabled: bool
    pubsub_active_slots: int
    total_websocket_connections: int
    web_connections: int
    device_connections: int
    recent_errors: List[AdminLogEntry]


@dataclass
class AdminCommandHistory:
    """Command history entry for user diagnostics."""
    timestamp: str
    action: Optional[str]
    accessory_id: Optional[str]
    accessory_name: Optional[str]
    success: Optional[bool]
    latency_ms: Optional[int]
    error: Optional[str]


@dataclass
class AdminConnectionEvent:
    """Connection event for user diagnostics."""
    timestamp: str
    event: str
    details: Optional[str]


@dataclass
class AdminUserDiagnostics:
    """Per-user diagnostics for admin panel."""
    user_id: str
    user_email: str
    websocket_connected: bool
    device_connected: bool
    routing_mode: str
    device_name: Optional[str]
    device_last_seen: Optional[str]
    recent_commands: List[AdminCommandHistory]
    connection_history: List[AdminConnectionEvent]


@dataclass
class AdminPingResult:
    """Result of pinging a user's device."""
    success: bool
    latency_ms: Optional[int] = None
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
        home_id=data.get("homeId"),
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
                last_login_at=user.last_login_at.isoformat() if user.last_login_at else None,
                is_admin=user.is_admin
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

    # --- Stored Entity Endpoints ---

    @field
    async def stored_entities(self, entity_type: str) -> List[StoredEntityInfo]:
        """Get all stored entities of a type for the authenticated user."""
        auth = require_auth()
        with get_session() as session:
            entities = StoredEntityRepository.get_entities_by_type(
                session, auth.user_id, entity_type
            )
            return [StoredEntityInfo(
                id=str(e.id),
                entity_type=e.entity_type,
                entity_id=e.entity_id,
                parent_id=e.parent_id,
                data_json=e.data_json,
                layout_json=e.layout_json,
                updated_at=e.updated_at.isoformat()
            ) for e in entities]

    @field
    async def stored_entity_layout(self, entity_type: str, entity_id: str) -> Optional[StoredEntityInfo]:
        """Get a specific entity's layout."""
        auth = require_auth()
        with get_session() as session:
            entity = StoredEntityRepository.get_entity(
                session, auth.user_id, entity_type, entity_id
            )
            if not entity:
                return None
            return StoredEntityInfo(
                id=str(entity.id),
                entity_type=entity.entity_type,
                entity_id=entity.entity_id,
                parent_id=entity.parent_id,
                data_json=entity.data_json,
                layout_json=entity.layout_json,
                updated_at=entity.updated_at.isoformat()
            )

    @field(mutable=True)
    async def sync_entities(
        self,
        entities: List[dict]  # [{entityType, entityId, parentId?, dataJson}]
    ) -> SyncEntitiesResult:
        """Sync entities from device (bulk upsert). Preserves existing layouts."""
        auth = require_auth()
        with get_session() as session:
            # Transform frontend format to backend format
            backend_entities = []
            for e in entities:
                backend_entities.append({
                    "entity_type": e.get("entityType"),
                    "entity_id": e.get("entityId"),
                    "parent_id": e.get("parentId"),
                    "data_json": e.get("dataJson", "{}")
                })
            results = StoredEntityRepository.bulk_upsert(
                session, auth.user_id, backend_entities
            )
            return SyncEntitiesResult(success=True, synced_count=len(results))

    @field(mutable=True)
    async def update_stored_entity_layout(
        self,
        entity_type: str,
        entity_id: str,
        layout_json: str
    ) -> UpdateEntityLayoutResult:
        """Update just the layout for an entity."""
        auth = require_auth()

        # Validate it's valid JSON
        try:
            json.loads(layout_json)
        except json.JSONDecodeError:
            return UpdateEntityLayoutResult(success=False)

        with get_session() as session:
            entity = StoredEntityRepository.update_layout(
                session, auth.user_id, entity_type, entity_id, layout_json
            )
            if entity:
                return UpdateEntityLayoutResult(
                    success=True,
                    entity=StoredEntityInfo(
                        id=str(entity.id),
                        entity_type=entity.entity_type,
                        entity_id=entity.entity_id,
                        parent_id=entity.parent_id,
                        data_json=entity.data_json,
                        layout_json=entity.layout_json,
                        updated_at=entity.updated_at.isoformat()
                    )
                )
            return UpdateEntityLayoutResult(success=False)

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

    @field
    async def connection_debug_info(self) -> ConnectionDebugInfo:
        """Get debug information about server connection and routing."""
        from homecast.websocket.handler import get_user_device_id, connection_manager
        from homecast.websocket.pubsub_router import pubsub_router, _get_instance_id

        auth = require_auth()

        # Get server instance info
        server_instance_id = _get_instance_id()
        pubsub_enabled = pubsub_router.enabled
        pubsub_slot = pubsub_router._slot_name if pubsub_enabled else None

        # Get device info
        device_id = await get_user_device_id(auth.user_id)
        device_connected = device_id is not None
        device_instance_id = None
        routing_mode = "not_connected"

        if device_id:
            # Check if device is local
            is_local = device_id in connection_manager.connections
            if is_local:
                routing_mode = "local"
                device_instance_id = server_instance_id
            else:
                # Device is on another instance - look up from DB
                with get_session() as db:
                    session = SessionRepository.get_device_session(db, device_id)
                    if session:
                        device_instance_id = session.instance_id
                        routing_mode = "pubsub" if pubsub_enabled else "unreachable"

        return ConnectionDebugInfo(
            server_instance_id=server_instance_id,
            pubsub_enabled=pubsub_enabled,
            pubsub_slot=pubsub_slot,
            device_connected=device_connected,
            device_id=device_id,
            device_instance_id=device_instance_id,
            routing_mode=routing_mode
        )

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
            raise GraphQLError("No connected device. Please ensure your HomeKit device is running and connected.")

        try:
            result = await route_request(
                device_id=device_id,
                action="homes.list",
                payload={}
            )
            return [parse_home(h) for h in result.get("homes", [])]
        except TimeoutError as e:
            logger.error(f"homes.list timeout: {e}", exc_info=True)
            raise GraphQLError("Device did not respond in time. Please check your connection.")
        except Exception as e:
            logger.error(f"homes.list error: {type(e).__name__}: {e}", exc_info=True)
            raise GraphQLError(f"Failed to fetch homes: {e}")

    @field
    async def rooms(self, home_id: str) -> List[HomeKitRoom]:
        """List rooms in a home. Requires authentication and connected device."""
        from homecast.websocket.handler import route_request, get_user_device_id

        auth = require_auth()
        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            raise GraphQLError("No connected device. Please ensure your HomeKit device is running and connected.")

        try:
            result = await route_request(
                device_id=device_id,
                action="rooms.list",
                payload={"homeId": home_id}
            )
            return [parse_room(r) for r in result.get("rooms", [])]
        except TimeoutError as e:
            logger.error(f"rooms.list timeout: {e}", exc_info=True)
            raise GraphQLError("Device did not respond in time. Please check your connection.")
        except Exception as e:
            logger.error(f"rooms.list error: {type(e).__name__}: {e}", exc_info=True)
            raise GraphQLError(f"Failed to fetch rooms: {e}")

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
            raise GraphQLError("No connected device. Please ensure your HomeKit device is running and connected.")

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
        except TimeoutError as e:
            logger.error(f"accessories.list timeout: {e}", exc_info=True)
            raise GraphQLError("Device did not respond in time. Please check your connection.")
        except Exception as e:
            logger.error(f"accessories.list error: {type(e).__name__}: {e}", exc_info=True)
            raise GraphQLError(f"Failed to fetch accessories: {e}")

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
        import time
        from homecast.websocket.handler import route_request, get_user_device_id
        from homecast.utils.system_logger import SystemLogger, get_trace_context_from_request, generate_trace_id

        start_time = time.time()
        auth = require_auth()

        # Get trace context from request headers or generate new one
        trace_ctx = get_trace_context_from_request()
        trace_id = trace_ctx['trace_id'] if trace_ctx else generate_trace_id()

        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            SystemLogger.warning(
                "api", "set_characteristic failed - no connected device",
                user_id=auth.user_id, trace_id=trace_id, span_name="server_received",
                action="set_characteristic", accessory_id=accessory_id,
                characteristic_type=characteristic_type, success=False,
                error="No connected device"
            )
            raise ValueError("No connected device")

        # Parse the JSON value
        try:
            parsed_value = json.loads(value)
        except json.JSONDecodeError:
            raise ValueError(f"Invalid JSON value: {value}")

        # Log: server received
        SystemLogger.info(
            "api", "set_characteristic received",
            user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
            span_name="server_received", action="set_characteristic",
            accessory_id=accessory_id, characteristic_type=characteristic_type,
            value=value
        )

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

            latency_ms = int((time.time() - start_time) * 1000)
            success = result.get("success", True)

            # Log: response sent
            SystemLogger.info(
                "api", "set_characteristic completed",
                user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
                span_name="response_sent", action="set_characteristic",
                accessory_id=accessory_id, characteristic_type=characteristic_type,
                value=json.dumps(result.get("value", parsed_value)),
                success=success, latency_ms=latency_ms
            )

            return SetCharacteristicResult(
                success=success,
                accessory_id=accessory_id,
                characteristic_type=characteristic_type,
                value=json.dumps(result.get("value", parsed_value))
            )
        except Exception as e:
            latency_ms = int((time.time() - start_time) * 1000)

            # Log: error
            SystemLogger.error(
                "api", f"set_characteristic failed: {e}",
                user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
                span_name="response_sent", action="set_characteristic",
                accessory_id=accessory_id, characteristic_type=characteristic_type,
                success=False, error=str(e), latency_ms=latency_ms
            )

            logger.error(f"characteristic.set error: {e}")
            raise

    @field(mutable=True)
    async def execute_scene(self, scene_id: str) -> ExecuteSceneResult:
        """Execute a scene."""
        import time
        from homecast.websocket.handler import route_request, get_user_device_id
        from homecast.utils.system_logger import SystemLogger, get_trace_context_from_request, generate_trace_id

        start_time = time.time()
        auth = require_auth()

        # Get trace context from request headers or generate new one
        trace_ctx = get_trace_context_from_request()
        trace_id = trace_ctx['trace_id'] if trace_ctx else generate_trace_id()

        device_id = await get_user_device_id(auth.user_id)

        if not device_id:
            SystemLogger.warning(
                "api", "execute_scene failed - no connected device",
                user_id=auth.user_id, trace_id=trace_id, span_name="server_received",
                action="execute_scene", success=False, error="No connected device",
                metadata={"scene_id": scene_id}
            )
            raise ValueError("No connected device")

        # Log: server received
        SystemLogger.info(
            "api", "execute_scene received",
            user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
            span_name="server_received", action="execute_scene",
            metadata={"scene_id": scene_id}
        )

        try:
            result = await route_request(
                device_id=device_id,
                action="scene.execute",
                payload={"sceneId": scene_id}
            )

            latency_ms = int((time.time() - start_time) * 1000)
            success = result.get("success", True)

            # Log: response sent
            SystemLogger.info(
                "api", "execute_scene completed",
                user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
                span_name="response_sent", action="execute_scene",
                success=success, latency_ms=latency_ms,
                metadata={"scene_id": scene_id}
            )

            return ExecuteSceneResult(
                success=success,
                scene_id=scene_id
            )
        except Exception as e:
            latency_ms = int((time.time() - start_time) * 1000)

            # Log: error
            SystemLogger.error(
                "api", f"execute_scene failed: {e}",
                user_id=auth.user_id, device_id=device_id, trace_id=trace_id,
                span_name="response_sent", action="execute_scene",
                success=False, error=str(e), latency_ms=latency_ms,
                metadata={"scene_id": scene_id}
            )

            logger.error(f"scene.execute error: {e}")
            raise

    # --- Collection Endpoints ---
    # Collections are stored in StoredEntity table with entity_type='collection'

    def _stored_entity_to_collection(self, entity: StoredEntity) -> Collection:
        """Convert StoredEntity to Collection format for API compatibility."""
        data = json.loads(entity.data_json) if entity.data_json else {}
        layout = json.loads(entity.layout_json) if entity.layout_json else {}

        # Reconstruct payload from data_json (contains groups and items)
        payload = json.dumps({
            "groups": data.get("groups", []),
            "items": data.get("items", [])
        })

        return Collection(
            id=entity.entity_id,
            name=data.get("name", ""),
            payload=payload,
            created_at=entity.created_at.isoformat(),
            settings_json=json.dumps(layout) if layout else None
        )

    @field
    async def collections(self) -> List[Collection]:
        """Get all collections for the current user. Requires authentication."""
        auth = require_auth()
        with get_session() as session:
            entities = StoredEntityRepository.get_entities_by_type(
                session, auth.user_id, 'collection'
            )
            return [self._stored_entity_to_collection(e) for e in entities]

    @field
    async def collection(self, collection_id: str) -> Optional[Collection]:
        """Get a specific collection. Requires authentication."""
        auth = require_auth()
        with get_session() as session:
            entity = StoredEntityRepository.get_entity(
                session, auth.user_id, 'collection', collection_id
            )
            return self._stored_entity_to_collection(entity) if entity else None

    @field(mutable=True)
    async def create_collection(self, name: str) -> Optional[Collection]:
        """Create a new collection. Requires authentication."""
        auth = require_auth()
        if not name or not name.strip():
            raise ValueError("Name is required")

        import uuid as uuid_module
        collection_id = str(uuid_module.uuid4())

        with get_session() as session:
            # Create collection in StoredEntity
            entity = StoredEntityRepository.upsert_entity(
                session, auth.user_id, 'collection', collection_id,
                data_json=json.dumps({'name': name.strip(), 'items': [], 'groups': []}),
                layout_json='{}'
            )

            # Create owner access via EntityAccess (for sharing system)
            access = EntityAccess(
                entity_type="collection",
                entity_id=uuid_module.UUID(collection_id),
                owner_id=auth.user_id,
                access_type="user",
                user_id=auth.user_id,
                role="owner"
            )
            session.add(access)
            session.commit()

            return self._stored_entity_to_collection(entity)

    @field(mutable=True)
    async def update_collection(
        self,
        collection_id: str,
        name: Optional[str] = None,
        payload: Optional[str] = None,
        settings_json: Optional[str] = None
    ) -> Optional[Collection]:
        """Update a collection. Requires authentication and owner role."""
        auth = require_auth()

        # Validate payload format - each item must have home_id for sharing to work
        if payload:
            try:
                payload_data = json.loads(payload)
                items = payload_data if isinstance(payload_data, list) else payload_data.get("items", [])
                for item in items:
                    if item.get("accessory_id") and not item.get("home_id"):
                        raise ValueError(f"Item with accessory_id {item.get('accessory_id')} missing home_id")
            except json.JSONDecodeError:
                return None
            except ValueError as e:
                logger.warning(f"Collection payload validation failed: {e}")
                return None

        with get_session() as session:
            # Get existing entity
            entity = StoredEntityRepository.get_entity(
                session, auth.user_id, 'collection', collection_id
            )
            if not entity:
                return None

            # Parse existing data and update
            data = json.loads(entity.data_json) if entity.data_json else {}

            if name is not None:
                data['name'] = name.strip()

            if payload is not None:
                payload_data = json.loads(payload)
                if isinstance(payload_data, list):
                    # Old array format - convert to new format
                    data['items'] = payload_data
                    data['groups'] = []
                else:
                    # New object format
                    data['items'] = payload_data.get('items', [])
                    data['groups'] = payload_data.get('groups', [])

            # Update data_json
            entity = StoredEntityRepository.upsert_entity(
                session, auth.user_id, 'collection', collection_id,
                data_json=json.dumps(data)
            )

            # Update layout_json if settings provided
            if settings_json is not None:
                entity = StoredEntityRepository.update_layout(
                    session, auth.user_id, 'collection', collection_id, settings_json
                )

            return self._stored_entity_to_collection(entity) if entity else None

    @field(mutable=True)
    async def delete_collection(self, collection_id: str) -> bool:
        """Delete a collection. Requires authentication and owner role."""
        auth = require_auth()
        import uuid as uuid_module

        with get_session() as session:
            # Delete all EntityAccess records for this collection first
            try:
                cid = uuid_module.UUID(collection_id)
                from sqlmodel import select
                access_records = session.exec(
                    select(EntityAccess)
                    .where(EntityAccess.entity_type == "collection")
                    .where(EntityAccess.entity_id == cid)
                ).all()
                for record in access_records:
                    session.delete(record)
                session.flush()
            except ValueError:
                pass  # Invalid UUID, skip entity access cleanup

            # Delete the stored entity
            return StoredEntityRepository.delete_entity(
                session, auth.user_id, 'collection', collection_id
            )

    # --- Entity Access Endpoints (Unified Sharing) ---

    def _entity_access_to_info(self, access: EntityAccess, user_email: Optional[str] = None) -> EntityAccessInfo:
        """Convert EntityAccess model to EntityAccessInfo dataclass."""
        return EntityAccessInfo(
            id=str(access.id),
            entity_type=access.entity_type,
            entity_id=str(access.entity_id),
            access_type=access.access_type,
            role=access.role,
            name=access.name,
            user_id=str(access.user_id) if access.user_id else None,
            user_email=user_email,
            has_passcode=access.passcode_hash is not None,
            access_schedule=access.access_schedule,
            created_at=access.created_at.isoformat() if access.created_at else None
        )

    @field
    async def entity_access(self, entity_type: str, entity_id: str) -> List[EntityAccessInfo]:
        """
        Get all access configs for an entity. Requires authentication and ownership.

        Args:
            entity_type: Type of entity (collection, room, accessory_group, home, accessory, room_group)
            entity_id: Entity UUID

        Returns:
            List of EntityAccessInfo records
        """
        auth = require_auth()

        try:
            eid = __import__('uuid').UUID(entity_id)
        except ValueError:
            return []

        with get_session() as session:
            # Get all access records
            access_list = EntityAccessRepository.get_entity_access(session, entity_type, eid)

            # Verify user is owner
            if not access_list:
                return []

            is_owner = any(a.owner_id == auth.user_id for a in access_list)
            if not is_owner:
                return []

            # Resolve user emails for user access types
            result = []
            for access in access_list:
                user_email = None
                if access.access_type == "user" and access.user_id:
                    user = UserRepository.find_by_id(session, access.user_id)
                    user_email = user.email if user else None
                result.append(self._entity_access_to_info(access, user_email))

            return result

    @field
    async def sharing_info(self, entity_type: str, entity_id: str) -> Optional[SharingInfo]:
        """
        Get sharing summary for an entity. Requires authentication and ownership.

        Args:
            entity_type: Type of entity
            entity_id: Entity UUID

        Returns:
            SharingInfo or None if not owner
        """
        auth = require_auth()

        try:
            eid = __import__('uuid').UUID(entity_id)
        except ValueError:
            return None

        with get_session() as session:
            # Get sharing info
            info = EntityAccessRepository.get_sharing_info(session, entity_type, eid)

            # Verify ownership by checking if any access record has this user as owner
            access_list = EntityAccessRepository.get_entity_access(session, entity_type, eid)
            is_owner = any(a.owner_id == auth.user_id for a in access_list)

            # Allow if owner OR if no shares exist yet (for initial setup)
            if not is_owner and access_list:
                return None

            return SharingInfo(
                is_shared=info["is_shared"],
                has_public=info["has_public"],
                public_role=info["public_role"],
                passcode_count=info["passcode_count"],
                user_count=info["user_count"],
                share_hash=info["share_hash"],
                share_url=f"https://homecast.cloud/s/{info['share_hash']}"
            )

    @field
    async def my_shared_entities(self) -> List[EntityAccessInfo]:
        """
        Get all entities shared WITH the current user.

        Returns:
            List of EntityAccessInfo records where user has user-specific access
        """
        auth = require_auth()

        with get_session() as session:
            access_list = EntityAccessRepository.get_user_shared_entities(session, auth.user_id)
            return [self._entity_access_to_info(a) for a in access_list]

    @field(mutable=True)
    async def create_entity_access(
        self,
        entity_type: str,
        entity_id: str,
        access_type: str,
        role: str = "view",
        home_id: Optional[str] = None,
        user_email: Optional[str] = None,
        passcode: Optional[str] = None,
        name: Optional[str] = None,
        access_schedule: Optional[str] = None
    ) -> CreateEntityAccessResult:
        """
        Create a new access config for an entity. Requires authentication.

        Args:
            entity_type: Type of entity (collection, room, accessory_group, home, accessory, room_group)
            entity_id: Entity UUID
            access_type: Type of access (public, passcode, user)
            role: Permission level (view, control)
            home_id: Required for room/accessory_group/accessory
            user_email: Email of user to grant access (for access_type="user")
            passcode: Passcode (for access_type="passcode")
            name: Label for passcode
            access_schedule: JSON schedule config

        Returns:
            CreateEntityAccessResult
        """
        auth = require_auth()

        try:
            eid = __import__('uuid').UUID(entity_id)
            hid = __import__('uuid').UUID(home_id) if home_id else None
        except ValueError:
            return CreateEntityAccessResult(success=False, error="Invalid UUID")

        # Require home_id for room/accessory_group/accessory (needed for fetching accessories)
        if entity_type in ("room", "accessory_group", "accessory") and not hid:
            return CreateEntityAccessResult(success=False, error=f"home_id is required for {entity_type}")

        # For collection_group, home_id stores the collection_id
        if entity_type == "collection_group" and not hid:
            return CreateEntityAccessResult(success=False, error="home_id (collection_id) is required for collection_group")

        # For user access, resolve email to user_id
        user_id = None
        if access_type == "user":
            if not user_email:
                return CreateEntityAccessResult(success=False, error="Email required for user access")
            with get_session() as session:
                user = UserRepository.find_by_email(session, user_email)
                if not user:
                    return CreateEntityAccessResult(success=False, error="User not found")
                user_id = user.id

        try:
            with get_session() as session:
                # For collections, verify ownership via StoredEntityRepository
                if entity_type == "collection":
                    entity = StoredEntityRepository.get_entity(
                        session, auth.user_id, 'collection', str(eid)
                    )
                    if not entity:
                        return CreateEntityAccessResult(success=False, error="Not authorized")

                access = EntityAccessRepository.create_access(
                    session=session,
                    entity_type=entity_type,
                    entity_id=eid,
                    owner_id=auth.user_id,
                    access_type=access_type,
                    role=role,
                    home_id=hid,
                    user_id=user_id,
                    passcode=passcode,
                    name=name,
                    access_schedule=access_schedule
                )

                return CreateEntityAccessResult(
                    success=True,
                    access=self._entity_access_to_info(access, user_email)
                )

        except ValueError as e:
            return CreateEntityAccessResult(success=False, error=str(e))
        except Exception as e:
            logger.error(f"create_entity_access error: {e}", exc_info=True)
            return CreateEntityAccessResult(success=False, error="Failed to create access")

    @field(mutable=True)
    async def update_entity_access(
        self,
        access_id: str,
        role: Optional[str] = None,
        passcode: Optional[str] = None,
        name: Optional[str] = None,
        access_schedule: Optional[str] = None
    ) -> CreateEntityAccessResult:
        """
        Update an access config. Requires authentication and ownership.

        Args:
            access_id: Access record ID
            role: New role (optional)
            passcode: New passcode (optional, only for passcode access)
            name: New name (optional)
            access_schedule: New schedule (optional)

        Returns:
            CreateEntityAccessResult
        """
        auth = require_auth()

        try:
            aid = __import__('uuid').UUID(access_id)
        except ValueError:
            return CreateEntityAccessResult(success=False, error="Invalid access ID")

        try:
            with get_session() as session:
                access = EntityAccessRepository.update_access(
                    session=session,
                    access_id=aid,
                    owner_id=auth.user_id,
                    role=role,
                    passcode=passcode,
                    name=name,
                    access_schedule=access_schedule
                )

                if not access:
                    return CreateEntityAccessResult(success=False, error="Not found or not authorized")

                return CreateEntityAccessResult(
                    success=True,
                    access=self._entity_access_to_info(access)
                )

        except ValueError as e:
            return CreateEntityAccessResult(success=False, error=str(e))
        except Exception as e:
            logger.error(f"update_entity_access error: {e}", exc_info=True)
            return CreateEntityAccessResult(success=False, error="Failed to update access")

    @field(mutable=True)
    async def delete_entity_access(self, access_id: str) -> DeleteEntityAccessResult:
        """
        Delete an access config. Requires authentication and ownership.

        Args:
            access_id: Access record ID

        Returns:
            DeleteEntityAccessResult
        """
        auth = require_auth()

        try:
            aid = __import__('uuid').UUID(access_id)
        except ValueError:
            return DeleteEntityAccessResult(success=False, error="Invalid access ID")

        with get_session() as session:
            success = EntityAccessRepository.delete_access(session, aid, auth.user_id)

            if not success:
                return DeleteEntityAccessResult(success=False, error="Not found or not authorized")

            return DeleteEntityAccessResult(success=True)

    # --- Public Entity Endpoints (no auth required) ---

    @field
    async def public_entity(
        self,
        share_hash: str,
        passcode: Optional[str] = None
    ) -> Optional[SharedEntityData]:
        """
        Get a shared entity by its share hash. No authentication required.

        Args:
            share_hash: The hash from the share URL (e.g., "c86974af0ab3")
            passcode: Optional passcode for elevated access

        Returns:
            SharedEntityData or None if access denied
        """
        # Try to get authenticated user (optional)
        auth = get_auth_context()
        user_id = auth.user_id if auth else None

        with get_session() as session:
            access, entity_type, entity_id = EntityAccessRepository.verify_access_by_hash(
                session, share_hash, passcode, user_id
            )

            if not access:
                # Check if entity exists but requires passcode
                try:
                    decoded_type, id_prefix, _ = decode_share_hash(share_hash)
                    # Find if any passcode access exists
                    entity_id_found = EntityAccessRepository._find_entity_by_prefix(
                        session, decoded_type, id_prefix
                    )
                    if entity_id_found:
                        passcode_access = EntityAccessRepository.get_passcode_access(
                            session, decoded_type, entity_id_found
                        )
                        if passcode_access:
                            # Entity exists but requires passcode
                            return SharedEntityData(
                                entity_type=decoded_type,
                                entity_id=str(entity_id_found),
                                entity_name="",  # Don't reveal name
                                role="view",
                                requires_passcode=True
                            )
                except ValueError:
                    pass
                return None

            # Get entity data based on type
            entity_name = ""
            entity_data = None

            if entity_type == "collection":
                collection_entity = StoredEntityRepository.get_entity(
                    session, access.owner_id, 'collection', str(entity_id)
                )
                if collection_entity:
                    data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                    layout = json.loads(collection_entity.layout_json) if collection_entity.layout_json else {}
                    entity_name = data.get("name", "")
                    # Reconstruct payload format for backward compatibility
                    entity_data = json.dumps({
                        "payload": json.dumps({
                            "groups": data.get("groups", []),
                            "items": data.get("items", [])
                        }),
                        "settings_json": json.dumps(layout) if layout else None
                    })

            elif entity_type == "collection_group":
                # For collection_group, home_id stores the collection_id
                collection_id = access.home_id
                if collection_id:
                    collection_entity = StoredEntityRepository.get_entity(
                        session, access.owner_id, 'collection', str(collection_id)
                    )
                    if collection_entity:
                        # Find the group name from the collection's data
                        try:
                            data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                            groups = data.get("groups", [])
                            group_id_str = str(entity_id)
                            for group in groups:
                                if group.get("id") == group_id_str:
                                    entity_name = group.get("name", "Group")
                                    break
                        except json.JSONDecodeError:
                            pass

            elif entity_type == "room_group":
                # Room group: a subset of rooms from a home
                group_entity = StoredEntityRepository.get_entity(
                    session, access.owner_id, 'room_group', str(entity_id)
                )
                if group_entity:
                    data = json.loads(group_entity.data_json) if group_entity.data_json else {}
                    entity_name = data.get("name", "Room Group")
                    # Include roomIds in the data for the frontend
                    entity_data = json.dumps({
                        "name": entity_name,
                        "roomIds": data.get("roomIds", []),
                        "homeId": group_entity.parent_id
                    })

            # For other types (room, home, accessory, accessory_group), we'd fetch from HomeKit
            # via the owner's device. For now, return the basic info.

            # Check if user can upgrade to control with a passcode
            # (only if current role is view and no passcode was provided)
            can_upgrade_with_passcode = False
            if access.role == "view" and not passcode:
                # Check if there's a passcode access with control role
                passcode_accesses = EntityAccessRepository.get_passcode_access(
                    session, entity_type, entity_id
                )
                if passcode_accesses:
                    # Check if any passcode grants control
                    for pa in passcode_accesses:
                        if pa.role == "control":
                            can_upgrade_with_passcode = True
                            break

            return SharedEntityData(
                entity_type=entity_type,
                entity_id=str(entity_id),
                entity_name=entity_name,
                role=access.role,
                requires_passcode=False,
                can_upgrade_with_passcode=can_upgrade_with_passcode,
                data=entity_data
            )

    @field
    async def public_entity_accessories(
        self,
        share_hash: str,
        passcode: Optional[str] = None
    ) -> Optional[str]:
        """
        Fetch full accessory data for a shared entity from owner's device.

        Args:
            share_hash: The hash from the share URL
            passcode: Optional passcode for elevated access

        Returns:
            JSON string of HomeKitAccessory[] or None if access denied
        """
        from homecast.websocket.handler import route_request, get_user_device_id

        # Try to get authenticated user (optional)
        auth = get_auth_context()
        user_id = auth.user_id if auth else None

        with get_session() as session:
            access, entity_type, entity_id = EntityAccessRepository.verify_access_by_hash(
                session, share_hash, passcode, user_id
            )

            if not access:
                return None

            # Get owner's device
            owner_id = access.owner_id
            home_id = access.home_id  # For room/accessory, this is required

            # Determine what to fetch based on entity type
            accessory_ids = None  # None means fetch all, set() means filter
            service_group_ids = None  # None means fetch all, set() means filter to specific groups
            home_ids = set()
            room_group_room_ids = None  # For room_group: filter to only accessories in these rooms

            if entity_type == "collection":
                # Get collection from StoredEntity and parse items
                collection_entity = StoredEntityRepository.get_entity(
                    session, owner_id, 'collection', str(entity_id)
                )
                if not collection_entity:
                    return None

                try:
                    data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                    items = data.get("items", [])
                except json.JSONDecodeError:
                    return None

                # Extract accessory IDs, service group IDs, and home IDs from collection
                accessory_ids = set()
                service_group_ids = set()  # Will filter to only these service groups
                for item in items:
                    item_home_id = item.get("home_id")
                    if item_home_id:
                        home_ids.add(item_home_id)
                    if item.get("accessory_id"):
                        accessory_ids.add(item["accessory_id"])
                    if item.get("service_group_id"):
                        service_group_ids.add(item["service_group_id"])

                # If no accessories AND no service groups, collection is empty
                if not accessory_ids and not service_group_ids:
                    logger.info(f"Collection {entity_id} has no accessories or service groups")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

                if not home_ids:
                    logger.warning(f"Collection {entity_id} has items but no home_ids in payload")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

            elif entity_type == "collection_group":
                # Get collection (stored in home_id field) and filter by group_id (entity_id)
                collection_id = home_id  # For collection_group, home_id stores collection_id
                if not collection_id:
                    logger.warning(f"Collection group share missing collection_id")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

                # Get collection from StoredEntity
                collection_entity = StoredEntityRepository.get_entity(
                    session, owner_id, 'collection', str(collection_id)
                )
                if not collection_entity:
                    logger.warning(f"Collection {collection_id} not found for group share")
                    return None

                try:
                    data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                    items = data.get("items", [])
                    groups = data.get("groups", [])
                except json.JSONDecodeError:
                    return None

                # Filter items by group_id
                group_id_str = str(entity_id)
                accessory_ids = set()
                service_group_ids = set()
                for item in items:
                    if item.get("group_id") == group_id_str:
                        if item.get("accessory_id"):
                            accessory_ids.add(item["accessory_id"])
                            if item.get("home_id"):
                                home_ids.add(item["home_id"])
                        if item.get("service_group_id"):
                            service_group_ids.add(item["service_group_id"])
                            if item.get("home_id"):
                                home_ids.add(item["home_id"])

                if not accessory_ids and not service_group_ids:
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

                if not home_ids:
                    logger.warning(f"Collection group {entity_id} has items but no home_ids in payload")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

            elif entity_type == "room":
                # Fetch all accessories in the room
                if not home_id:
                    logger.warning(f"Room share {entity_id} missing home_id on EntityAccess")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})
                logger.info(f"Room share: entity_id={entity_id}, home_id={home_id}")
                home_ids.add(str(home_id))

            elif entity_type == "home":
                # Fetch all accessories in the home
                home_ids.add(str(entity_id))

            elif entity_type == "accessory":
                # Fetch single accessory
                if not home_id:
                    logger.warning(f"Accessory share {entity_id} missing home_id on EntityAccess")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})
                home_ids.add(str(home_id))
                accessory_ids = {str(entity_id)}

            elif entity_type == "accessory_group":
                # Service groups (HomeKit native accessory groups)
                if not home_id:
                    logger.warning(f"Accessory group share {entity_id} missing home_id on EntityAccess")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})
                home_ids.add(str(home_id))

            elif entity_type == "room_group":
                # Room group: a subset of rooms from a home
                group_entity = StoredEntityRepository.get_entity(
                    session, owner_id, 'room_group', str(entity_id)
                )
                if not group_entity:
                    logger.warning(f"Room group {entity_id} not found")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

                data = json.loads(group_entity.data_json) if group_entity.data_json else {}
                room_group_room_ids = set(data.get("roomIds", []))
                parent_home_id = group_entity.parent_id

                if not parent_home_id:
                    logger.warning(f"Room group {entity_id} has no parent home")
                    return json.dumps({"accessories": [], "serviceGroups": [], "layout": None})

                home_ids.add(parent_home_id)
                # room_group_room_ids will be used to filter accessories after fetching

            else:
                # Unsupported entity type
                return None

        # Route request to owner's device
        device_id = await get_user_device_id(owner_id)
        if not device_id:
            logger.warning(f"Owner's device not connected for share {share_hash}")
            return None

        # Track entity name for response
        resolved_entity_name = ""

        try:
            # First, fetch homes to build a home name mapping
            homes_result = await route_request(
                device_id=device_id,
                action="homes.list",
                payload={}
            )
            home_name_map = {}
            for home in homes_result.get("homes", []):
                home_name_map[home.get("id")] = home.get("name", "")
                # If this is a home share, capture the home name
                if entity_type == "home" and home.get("id") == str(entity_id):
                    resolved_entity_name = home.get("name", "")

            # Fetch accessories from each home
            all_accessories = []
            for hid in home_ids:
                result = await route_request(
                    device_id=device_id,
                    action="accessories.list",
                    payload={"homeId": hid}
                )
                # Inject homeName into each accessory
                for accessory in result.get("accessories", []):
                    accessory_home_id = accessory.get("homeId")
                    if accessory_home_id and accessory_home_id in home_name_map:
                        accessory["homeName"] = home_name_map[accessory_home_id]
                all_accessories.extend(result.get("accessories", []))

            # For collections with service groups, fetch service groups first
            # and expand accessory_ids to include service group member accessories
            all_service_groups = []
            if entity_type in ('collection', 'collection_group') and service_group_ids:
                for hid in home_ids:
                    try:
                        groups_result = await route_request(
                            device_id=device_id,
                            action="serviceGroups.list",
                            payload={"homeId": hid}
                        )
                        all_service_groups.extend(groups_result.get("serviceGroups", []))
                    except Exception as e:
                        logger.warning(f"Failed to fetch service groups for home {hid}: {e}")

                # Filter to only service groups in the collection
                normalized_sg_ids = {sgid.replace("-", "").lower() for sgid in service_group_ids}
                all_service_groups = [
                    sg for sg in all_service_groups
                    if sg.get("id", "").replace("-", "").lower() in normalized_sg_ids
                ]

                # Expand accessory_ids to include service group member accessories
                if accessory_ids is None:
                    accessory_ids = set()
                for sg in all_service_groups:
                    for aid in sg.get("accessoryIds", []):
                        accessory_ids.add(aid)
                logger.info(f"Collection: expanded accessory_ids to {len(accessory_ids)} after including service group members")

            # Filter based on entity type
            if entity_type == "room":
                # Filter to only accessories in this room
                # Normalize IDs for comparison (remove hyphens and lowercase)
                entity_id_normalized = str(entity_id).replace("-", "").lower()
                filtered_accessories = [
                    a for a in all_accessories
                    if str(a.get("roomId", "")).replace("-", "").lower() == entity_id_normalized
                ]
                # Get room name from first matching accessory
                if filtered_accessories and not resolved_entity_name:
                    resolved_entity_name = filtered_accessories[0].get("roomName", "")
                logger.info(f"Room filter: entity_id={entity_id}, normalized={entity_id_normalized}, "
                           f"total={len(all_accessories)}, filtered={len(filtered_accessories)}")
                if len(filtered_accessories) == 0 and len(all_accessories) > 0:
                    # Debug: log sample room IDs to help diagnose
                    sample_room_ids = [a.get("roomId") for a in all_accessories[:3]]
                    logger.warning(f"Room filter returned empty. Sample roomIds: {sample_room_ids}")
            elif entity_type == "accessory_group":
                # Filter to accessories in the service group (accessory group)
                # Fetch the service group to get its accessory IDs
                logger.info(f"Accessory group share: entity_id={entity_id}, home_id={home_id}")
                groups_result = await route_request(
                    device_id=device_id,
                    action="serviceGroups.list",
                    payload={"homeId": str(home_id)}
                )
                group_accessory_ids = set()
                entity_id_normalized = str(entity_id).replace("-", "").lower()
                found_group = False
                for group in groups_result.get("serviceGroups", []):
                    group_id_normalized = str(group.get("id", "")).replace("-", "").lower()
                    if group_id_normalized == entity_id_normalized:
                        found_group = True
                        group_accessory_ids = {
                            aid.replace("-", "").lower()
                            for aid in group.get("accessoryIds", [])
                        }
                        # Capture group name
                        if not resolved_entity_name:
                            resolved_entity_name = group.get("name", "")
                        logger.info(f"Accessory group filter: found group with {len(group_accessory_ids)} accessory IDs")
                        break

                if not found_group:
                    available_ids = [str(g.get("id", ""))[:8] for g in groups_result.get("serviceGroups", [])]
                    logger.warning(f"Accessory group filter: group {entity_id_normalized[:8]} not found in {len(groups_result.get('serviceGroups', []))} groups. Available: {available_ids}")
                else:
                    # Add the matching group to all_service_groups so it's included in the response
                    for group in groups_result.get("serviceGroups", []):
                        if str(group.get("id", "")).replace("-", "").lower() == entity_id_normalized:
                            all_service_groups.append(group)
                            break

                filtered_accessories = [
                    a for a in all_accessories
                    if a.get("id", "").replace("-", "").lower() in group_accessory_ids
                ]
                logger.info(f"Accessory group filter: total={len(all_accessories)}, filtered={len(filtered_accessories)}")
            elif entity_type == "room_group" and room_group_room_ids is not None:
                # Filter to accessories in the allowed rooms
                # Normalize room IDs for comparison (remove hyphens and lowercase)
                normalized_room_ids = {rid.replace("-", "").lower() for rid in room_group_room_ids}
                filtered_accessories = [
                    a for a in all_accessories
                    if str(a.get("roomId", "")).replace("-", "").lower() in normalized_room_ids
                ]
                logger.info(f"Room group filter: allowed_rooms={len(room_group_room_ids)}, "
                           f"total={len(all_accessories)}, filtered={len(filtered_accessories)}")
            elif accessory_ids is not None:
                # Filter to specific accessory IDs (collection or single accessory)
                # Normalize IDs for comparison (remove hyphens and lowercase)
                normalized_accessory_ids = {aid.replace("-", "").lower() for aid in accessory_ids}
                filtered_accessories = [
                    a for a in all_accessories
                    if a.get("id", "").replace("-", "").lower() in normalized_accessory_ids
                ]
                # Capture accessory name for single accessory shares
                if entity_type == "accessory" and filtered_accessories and not resolved_entity_name:
                    resolved_entity_name = filtered_accessories[0].get("name", "")
            else:
                # Return all (home entity type)
                filtered_accessories = all_accessories

            # Fetch service groups for the relevant homes (if not already fetched for collections)
            if not all_service_groups and entity_type in ('room', 'home', 'room_group'):
                for hid in home_ids:
                    try:
                        groups_result = await route_request(
                            device_id=device_id,
                            action="serviceGroups.list",
                            payload={"homeId": hid}
                        )
                        all_service_groups.extend(groups_result.get("serviceGroups", []))
                    except Exception as e:
                        logger.warning(f"Failed to fetch service groups for home {hid}: {e}")

            # Get layout from StoredEntity table
            layout = None
            with get_session() as session:
                entity_id_str = str(entity_id)
                if entity_type == 'home':
                    home_entity = StoredEntityRepository.get_entity(session, owner_id, 'home', entity_id_str)
                    if home_entity:
                        layout = json.loads(home_entity.layout_json) if home_entity.layout_json else {}
                        # Also get room layouts
                        room_entities = StoredEntityRepository.get_entities_by_parent(session, owner_id, entity_id_str)
                        layout['rooms'] = {e.entity_id: json.loads(e.layout_json) if e.layout_json else {} for e in room_entities}
                elif entity_type == 'room':
                    room_entity = StoredEntityRepository.get_entity(session, owner_id, 'room', entity_id_str)
                    if room_entity:
                        layout = json.loads(room_entity.layout_json) if room_entity.layout_json else {}
                elif entity_type == 'collection':
                    coll_entity = StoredEntityRepository.get_entity(session, owner_id, 'collection', entity_id_str)
                    if coll_entity:
                        layout = json.loads(coll_entity.layout_json) if coll_entity.layout_json else {}

            return json.dumps({
                "accessories": filtered_accessories,
                "serviceGroups": all_service_groups,
                "layout": layout,
                "entityName": resolved_entity_name
            })

        except Exception as e:
            logger.error(f"public_entity_accessories error: {e}")
            return None

    @field(mutable=True)
    async def public_entity_set_characteristic(
        self,
        share_hash: str,
        accessory_id: str,
        characteristic_type: str,
        value: str,
        passcode: Optional[str] = None
    ) -> SetCharacteristicResult:
        """
        Set a characteristic value via a shared entity link.

        Args:
            share_hash: The hash from the share URL
            accessory_id: Accessory UUID
            characteristic_type: Characteristic type
            value: JSON-encoded value
            passcode: Optional passcode

        Returns:
            SetCharacteristicResult
        """
        from homecast.websocket.handler import route_request, get_user_device_id

        # Try to get authenticated user (optional)
        auth = get_auth_context()
        user_id = auth.user_id if auth else None

        with get_session() as session:
            access, entity_type, entity_id = EntityAccessRepository.verify_access_by_hash(
                session, share_hash, passcode, user_id
            )

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

            # Verify accessory is within the shared entity scope
            if entity_type == "collection":
                # For collections, verify accessory is in collection
                collection_entity = StoredEntityRepository.get_entity(
                    session, access.owner_id, 'collection', str(entity_id)
                )
                if not collection_entity:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

                try:
                    data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                    items = data.get("items", [])
                except json.JSONDecodeError:
                    items = []

                # Extract accessory IDs from items
                accessory_ids = []
                for item in items:
                    if isinstance(item, dict):
                        aid = item.get("accessory_id") or item.get("item_id")
                        if aid:
                            accessory_ids.append(aid)

                if accessory_id not in accessory_ids:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

            elif entity_type == "collection_group":
                # For collection_group, verify accessory is in the group
                collection_id = access.home_id
                if not collection_id:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

                collection_entity = StoredEntityRepository.get_entity(
                    session, access.owner_id, 'collection', str(collection_id)
                )
                if not collection_entity:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

                try:
                    data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                    items = data.get("items", [])
                except json.JSONDecodeError:
                    items = []

                # Filter items by group_id and extract accessory_ids
                group_id_str = str(entity_id)
                accessory_ids = []
                for item in items:
                    if isinstance(item, dict) and item.get("group_id") == group_id_str:
                        aid = item.get("accessory_id")
                        if aid:
                            accessory_ids.append(aid)

                if accessory_id not in accessory_ids:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

            elif entity_type == "accessory":
                # For single accessory, must match exactly
                if str(entity_id) != accessory_id:
                    return SetCharacteristicResult(
                        success=False,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type
                    )

            elif entity_type == "room_group":
                # For room_group, we rely on the fact that public_entity_accessories
                # only returns accessories in the allowed rooms, so the frontend
                # can only show/control those accessories.
                # The device will reject if the accessory doesn't exist.
                pass

            # For room and home entity types, we'll verify the accessory belongs
            # to the room/home when routing the request (the device will reject
            # if the accessory doesn't exist in the requested home)

            # Get owner's device
            owner_id = access.owner_id

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
            logger.error(f"public_entity_set_characteristic error: {e}")
            raise

    # --- Room Group CRUD Endpoints ---

    @field
    async def room_groups(self, home_id: str) -> List[StoredEntityInfo]:
        """
        Get all room groups for a home. Requires authentication.

        Args:
            home_id: The home ID to get room groups for

        Returns:
            List of StoredEntityInfo records for room_group entities
        """
        auth = require_auth()

        with get_session() as session:
            # Get all room_group entities where parent_id matches the home_id
            entities = StoredEntityRepository.get_entities_by_parent(
                session, auth.user_id, home_id
            )
            # Filter to only room_group type
            room_groups = [e for e in entities if e.entity_type == 'room_group']
            return [StoredEntityInfo(
                id=str(e.id),
                entity_type=e.entity_type,
                entity_id=e.entity_id,
                parent_id=e.parent_id,
                data_json=e.data_json,
                layout_json=e.layout_json,
                updated_at=e.updated_at.isoformat()
            ) for e in room_groups]

    @field(mutable=True)
    async def create_room_group(
        self,
        name: str,
        home_id: str,
        room_ids: List[str]
    ) -> Optional[StoredEntityInfo]:
        """
        Create a new room group. Requires authentication.

        Args:
            name: Name of the room group
            home_id: Parent home ID
            room_ids: List of room IDs to include in the group

        Returns:
            Created StoredEntityInfo or None on failure
        """
        auth = require_auth()

        if not name or not name.strip():
            raise ValueError("Name is required")
        if not home_id:
            raise ValueError("home_id is required")
        if not room_ids:
            raise ValueError("At least one room_id is required")

        import uuid as uuid_module
        group_id = str(uuid_module.uuid4())

        with get_session() as session:
            # Create room_group in StoredEntity
            entity = StoredEntityRepository.upsert_entity(
                session, auth.user_id, 'room_group', group_id,
                parent_id=home_id,
                data_json=json.dumps({'name': name.strip(), 'roomIds': room_ids}),
                layout_json='{}'
            )

            return StoredEntityInfo(
                id=str(entity.id),
                entity_type=entity.entity_type,
                entity_id=entity.entity_id,
                parent_id=entity.parent_id,
                data_json=entity.data_json,
                layout_json=entity.layout_json,
                updated_at=entity.updated_at.isoformat()
            )

    @field(mutable=True)
    async def update_room_group(
        self,
        group_id: str,
        name: Optional[str] = None,
        room_ids: Optional[List[str]] = None
    ) -> Optional[StoredEntityInfo]:
        """
        Update a room group. Requires authentication.

        Args:
            group_id: The room group entity_id
            name: New name (optional)
            room_ids: New list of room IDs (optional)

        Returns:
            Updated StoredEntityInfo or None if not found
        """
        auth = require_auth()

        with get_session() as session:
            # Get existing entity
            entity = StoredEntityRepository.get_entity(
                session, auth.user_id, 'room_group', group_id
            )
            if not entity:
                return None

            # Parse existing data and update
            data = json.loads(entity.data_json) if entity.data_json else {}

            if name is not None:
                data['name'] = name.strip()

            if room_ids is not None:
                data['roomIds'] = room_ids

            # Update entity
            entity = StoredEntityRepository.upsert_entity(
                session, auth.user_id, 'room_group', group_id,
                parent_id=entity.parent_id,
                data_json=json.dumps(data)
            )

            return StoredEntityInfo(
                id=str(entity.id),
                entity_type=entity.entity_type,
                entity_id=entity.entity_id,
                parent_id=entity.parent_id,
                data_json=entity.data_json,
                layout_json=entity.layout_json,
                updated_at=entity.updated_at.isoformat()
            )

    @field(mutable=True)
    async def delete_room_group(self, group_id: str) -> bool:
        """
        Delete a room group. Requires authentication.

        Args:
            group_id: The room group entity_id

        Returns:
            True if deleted, False if not found
        """
        auth = require_auth()
        import uuid as uuid_module

        with get_session() as session:
            # Delete all EntityAccess records for this room_group first
            try:
                gid = uuid_module.UUID(group_id)
                from sqlmodel import select
                access_records = session.exec(
                    select(EntityAccess)
                    .where(EntityAccess.entity_type == "room_group")
                    .where(EntityAccess.entity_id == gid)
                ).all()
                for record in access_records:
                    session.delete(record)
                session.flush()
            except ValueError:
                pass  # Invalid UUID, skip entity access cleanup

            # Delete the stored entity
            return StoredEntityRepository.delete_entity(
                session, auth.user_id, 'room_group', group_id
            )

    # --- Admin Endpoints (require admin role) ---

    @field
    async def admin_users(
        self,
        limit: int = 50,
        offset: int = 0,
        search: Optional[str] = None
    ) -> AdminUsersResult:
        """
        Get all users with pagination. Requires admin role.

        Args:
            limit: Max number of users to return (default 50)
            offset: Number of users to skip (for pagination)
            search: Optional search query (email or name)

        Returns:
            AdminUsersResult with users and pagination info
        """
        from homecast.models.db.repositories import AdminRepository

        require_admin()

        with get_session() as session:
            users_data, total_count = AdminRepository.get_all_users(
                session, limit=limit, offset=offset, search=search
            )

            users = [
                AdminUserSummary(
                    id=u["id"],
                    email=u["email"],
                    name=u["name"],
                    created_at=u["created_at"],
                    last_login_at=u["last_login_at"],
                    is_active=u["is_active"],
                    is_admin=u["is_admin"],
                    device_count=u["device_count"],
                    home_count=u["home_count"],
                )
                for u in users_data
            ]

            return AdminUsersResult(
                users=users,
                total_count=total_count,
                has_more=(offset + limit) < total_count
            )

    @field
    async def admin_user_detail(self, user_id: str) -> Optional[AdminUserDetail]:
        """
        Get detailed information about a user. Requires admin role.

        Args:
            user_id: User UUID

        Returns:
            AdminUserDetail or None if not found
        """
        from homecast.models.db.repositories import AdminRepository
        import uuid as uuid_module

        require_admin()

        try:
            uid = uuid_module.UUID(user_id)
        except ValueError:
            return None

        with get_session() as session:
            user_data = AdminRepository.get_user_with_details(session, uid)
            if not user_data:
                return None

            return AdminUserDetail(
                id=user_data["id"],
                email=user_data["email"],
                name=user_data["name"],
                created_at=user_data["created_at"],
                last_login_at=user_data["last_login_at"],
                is_active=user_data["is_active"],
                is_admin=user_data["is_admin"],
                devices=[
                    AdminDeviceInfo(
                        id=d["id"],
                        device_id=d["device_id"],
                        name=d["name"],
                        session_type=d["session_type"],
                        last_seen_at=d["last_seen_at"],
                    )
                    for d in user_data["devices"]
                ],
                homes=[
                    AdminHomeInfo(id=h["id"], name=h["name"])
                    for h in user_data["homes"]
                ],
                settings_json=user_data["settings_json"],
            )

    @field
    async def admin_logs(
        self,
        level: Optional[str] = None,
        source: Optional[str] = None,
        user_id: Optional[str] = None,
        trace_id: Optional[str] = None,
        start_time: Optional[str] = None,
        end_time: Optional[str] = None,
        success: Optional[bool] = None,
        limit: int = 100,
        offset: int = 0
    ) -> AdminLogsResult:
        """
        Get system logs with filtering. Requires admin role.

        Args:
            level: Filter by log level (debug, info, warning, error)
            source: Filter by log source (api, websocket, pubsub, etc.)
            user_id: Filter by user UUID
            trace_id: Filter by trace ID
            start_time: Filter by start time (ISO 8601)
            end_time: Filter by end time (ISO 8601)
            success: Filter by success status
            limit: Max number of logs to return (default 100)
            offset: Number of logs to skip (for pagination)

        Returns:
            AdminLogsResult with logs and total count
        """
        from homecast.models.db.repositories import AdminRepository
        from datetime import datetime
        import uuid as uuid_module

        require_admin()

        # Parse optional parameters
        uid = None
        if user_id:
            try:
                uid = uuid_module.UUID(user_id)
            except ValueError:
                pass

        start_dt = None
        if start_time:
            try:
                start_dt = datetime.fromisoformat(start_time.replace('Z', '+00:00'))
            except ValueError:
                pass

        end_dt = None
        if end_time:
            try:
                end_dt = datetime.fromisoformat(end_time.replace('Z', '+00:00'))
            except ValueError:
                pass

        with get_session() as session:
            logs_data, total_count = AdminRepository.get_logs(
                session,
                level=level,
                source=source,
                user_id=uid,
                trace_id=trace_id,
                start_time=start_dt,
                end_time=end_dt,
                success=success,
                limit=limit,
                offset=offset
            )

            logs = [
                AdminLogEntry(
                    id=log["id"],
                    timestamp=log["timestamp"],
                    level=log["level"],
                    source=log["source"],
                    message=log["message"],
                    user_id=log["user_id"],
                    user_email=log["user_email"],
                    device_id=log["device_id"],
                    trace_id=log["trace_id"],
                    span_name=log["span_name"],
                    action=log["action"],
                    accessory_id=log["accessory_id"],
                    accessory_name=log["accessory_name"],
                    success=log["success"],
                    error=log["error"],
                    latency_ms=log["latency_ms"],
                    metadata=log["metadata"],
                )
                for log in logs_data
            ]

            return AdminLogsResult(logs=logs, total_count=total_count)

    @field
    async def admin_trace(self, trace_id: str) -> List[AdminLogEntry]:
        """
        Get all log entries for a trace. Requires admin role.

        Args:
            trace_id: The trace ID to look up

        Returns:
            List of AdminLogEntry ordered by timestamp
        """
        from homecast.models.db.repositories import AdminRepository

        require_admin()

        with get_session() as session:
            logs_data = AdminRepository.get_trace(session, trace_id)

            return [
                AdminLogEntry(
                    id=log["id"],
                    timestamp=log["timestamp"],
                    level=log["level"],
                    source=log["source"],
                    message=log["message"],
                    user_id=log["user_id"],
                    user_email=log["user_email"],
                    device_id=log["device_id"],
                    trace_id=log["trace_id"],
                    span_name=log["span_name"],
                    action=log["action"],
                    accessory_id=log["accessory_id"],
                    accessory_name=log["accessory_name"],
                    success=log["success"],
                    error=log["error"],
                    latency_ms=log["latency_ms"],
                    metadata=log["metadata"],
                )
                for log in logs_data
            ]

    @field
    async def admin_diagnostics(self) -> AdminSystemDiagnostics:
        """
        Get system-wide diagnostics. Requires admin role.

        Returns:
            AdminSystemDiagnostics with server instances and connection info
        """
        from homecast.models.db.repositories import AdminRepository

        require_admin()

        with get_session() as session:
            diag = AdminRepository.get_system_diagnostics(session)

            return AdminSystemDiagnostics(
                server_instances=[
                    AdminServerInstance(
                        instance_id=s["instance_id"],
                        slot_name=s.get("slot_name"),
                        last_heartbeat=s.get("last_heartbeat"),
                    )
                    for s in diag["server_instances"]
                ],
                pubsub_enabled=diag["pubsub_enabled"],
                pubsub_active_slots=diag["pubsub_active_slots"],
                total_websocket_connections=diag["total_websocket_connections"],
                web_connections=diag["web_connections"],
                device_connections=diag["device_connections"],
                recent_errors=[
                    AdminLogEntry(
                        id=log["id"],
                        timestamp=log["timestamp"],
                        level=log["level"],
                        source=log["source"],
                        message=log["message"],
                        user_id=log["user_id"],
                        user_email=log["user_email"],
                        device_id=log["device_id"],
                        trace_id=log.get("trace_id"),
                        span_name=log.get("span_name"),
                        action=log.get("action"),
                        accessory_id=log.get("accessory_id"),
                        accessory_name=log.get("accessory_name"),
                        success=log.get("success"),
                        error=log.get("error"),
                        latency_ms=log.get("latency_ms"),
                        metadata=log.get("metadata"),
                    )
                    for log in diag["recent_errors"]
                ],
            )

    @field
    async def admin_user_diagnostics(self, user_id: str) -> Optional[AdminUserDiagnostics]:
        """
        Get diagnostics for a specific user. Requires admin role.

        Args:
            user_id: User UUID

        Returns:
            AdminUserDiagnostics or None if user not found
        """
        from homecast.models.db.repositories import AdminRepository
        import uuid as uuid_module

        require_admin()

        try:
            uid = uuid_module.UUID(user_id)
        except ValueError:
            return None

        with get_session() as session:
            diag = AdminRepository.get_user_diagnostics(session, uid)
            if not diag:
                return None

            return AdminUserDiagnostics(
                user_id=diag["user_id"],
                user_email=diag["user_email"],
                websocket_connected=diag["websocket_connected"],
                device_connected=diag["device_connected"],
                routing_mode=diag["routing_mode"],
                device_name=diag["device_name"],
                device_last_seen=diag["device_last_seen"],
                recent_commands=[
                    AdminCommandHistory(
                        timestamp=cmd["timestamp"],
                        action=cmd["action"],
                        accessory_id=cmd["accessory_id"],
                        accessory_name=cmd["accessory_name"],
                        success=cmd["success"],
                        latency_ms=cmd["latency_ms"],
                        error=cmd["error"],
                    )
                    for cmd in diag["recent_commands"]
                ],
                connection_history=[
                    AdminConnectionEvent(
                        timestamp=evt["timestamp"],
                        event=evt["event"],
                        details=evt["details"],
                    )
                    for evt in diag["connection_history"]
                ],
            )

    @field(mutable=True)
    async def admin_toggle_user_active(self, user_id: str, is_active: bool) -> bool:
        """
        Enable or disable a user account. Requires admin role.

        Args:
            user_id: User UUID
            is_active: New active status

        Returns:
            True if successful, False if user not found
        """
        from homecast.models.db.repositories import AdminRepository
        import uuid as uuid_module

        require_admin()

        try:
            uid = uuid_module.UUID(user_id)
        except ValueError:
            return False

        with get_session() as session:
            return AdminRepository.toggle_user_active(session, uid, is_active)

    @field(mutable=True)
    async def admin_set_user_admin(self, user_id: str, is_admin: bool) -> bool:
        """
        Promote or demote a user to/from admin. Requires admin role.

        Args:
            user_id: User UUID
            is_admin: New admin status

        Returns:
            True if successful, False if user not found
        """
        from homecast.models.db.repositories import AdminRepository
        import uuid as uuid_module

        require_admin()

        try:
            uid = uuid_module.UUID(user_id)
        except ValueError:
            return False

        with get_session() as session:
            return AdminRepository.set_user_admin(session, uid, is_admin)

    @field(mutable=True)
    async def admin_force_disconnect(self, device_id: str) -> bool:
        """
        Force disconnect a device by removing its session. Requires admin role.

        Args:
            device_id: Device ID to disconnect

        Returns:
            True if successful, False if device not found
        """
        from homecast.models.db.repositories import AdminRepository

        require_admin()

        with get_session() as session:
            return AdminRepository.force_disconnect_device(session, device_id)

    @field(mutable=True)
    async def admin_clear_logs(self, before_date: Optional[str] = None) -> int:
        """
        Delete logs, optionally before a certain date. Requires admin role.

        Args:
            before_date: Delete logs before this date (ISO 8601)

        Returns:
            Number of logs deleted
        """
        from homecast.models.db.repositories import AdminRepository
        from datetime import datetime

        require_admin()

        before_dt = None
        if before_date:
            try:
                before_dt = datetime.fromisoformat(before_date.replace('Z', '+00:00'))
            except ValueError:
                pass

        with get_session() as session:
            return AdminRepository.clear_logs(session, before_dt)

    @field(mutable=True)
    async def admin_ping_device(self, user_id: str) -> AdminPingResult:
        """
        Ping a user's connected device to measure connectivity. Requires admin role.

        Args:
            user_id: User ID whose device to ping

        Returns:
            AdminPingResult with success, latency_ms, and error
        """
        from homecast.websocket.handler import get_user_device_id, route_ping
        import uuid as uuid_module

        require_admin()

        try:
            uid = uuid_module.UUID(user_id)
        except ValueError:
            return AdminPingResult(success=False, error="Invalid user ID")

        # Get the device ID for this user
        device_id = await get_user_device_id(uid)
        if not device_id:
            return AdminPingResult(success=False, error="No device connected for this user")

        # Route ping (handles local vs remote automatically)
        result = await route_ping(device_id)
        return AdminPingResult(
            success=result.get("success", False),
            latency_ms=result.get("latency_ms"),
            error=result.get("error")
        )
