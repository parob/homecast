"""
Database models for HomeCast.

Models:
- User: User accounts for the web portal
- Device: Connected HomeKit Mac apps
"""

import uuid
import re
from datetime import datetime, timezone
from typing import Optional
from enum import Enum

from graphql_db import GraphQLSQLAlchemyMixin
from sqlalchemy.ext.declarative import declared_attr
from sqlmodel import Field, SQLModel


class BaseModel(SQLModel):
    """Base model with common fields."""
    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc))

    @declared_attr  # type: ignore[misc]
    def __tablename__(cls):
        # Convert CamelCase to snake_case
        name = cls.__name__
        s1 = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
        s2 = re.sub('([a-z0-9])([A-Z])', r'\1_\2', s1)
        return s2.lower()


class GraphQLBaseModel(GraphQLSQLAlchemyMixin, BaseModel):
    """Base model with GraphQL support."""
    pass


class User(BaseModel, table=True):
    """
    User accounts for the web portal.

    Users sign up with email/password and can connect multiple devices.
    """
    __tablename__ = "users"

    email: str = Field(nullable=False, unique=True, index=True)
    password_hash: str = Field(nullable=False)

    # Profile
    name: Optional[str] = Field(default=None)

    # Settings (JSON string)
    settings_json: Optional[str] = Field(default=None)

    # Status
    is_active: bool = Field(default=True)
    is_admin: bool = Field(default=False, index=True)
    last_login_at: Optional[datetime] = Field(default=None)


class TopicSlot(SQLModel, table=True):
    """
    Pub/Sub topic slots for cross-instance routing.

    Instead of creating a topic per Cloud Run revision, we use a fixed pool
    of topics (e.g., homecast-a, homecast-b, etc.). Each instance claims
    a slot on startup and releases it on shutdown.
    """
    __tablename__ = "topic_slots"

    slot_name: str = Field(primary_key=True)  # e.g., "a", "b", "c"
    instance_id: Optional[str] = Field(default=None, index=True)  # Cloud Run revision ID
    claimed_at: Optional[datetime] = Field(default=None)
    last_heartbeat: Optional[datetime] = Field(default=None)


class SessionType(str, Enum):
    """Type of active session."""
    DEVICE = "device"  # Mac app connection
    WEB = "web"        # Web browser connection


class Session(BaseModel, table=True):
    """
    Active WebSocket connections (both Mac apps and web browsers).

    Tracks all active connections across all server instances.
    Used to determine if web clients are listening (for push updates)
    and which instance a device is connected to.
    """
    __tablename__ = "sessions"

    user_id: uuid.UUID = Field(nullable=False, foreign_key="users.id", index=True)
    instance_id: str = Field(nullable=False, index=True,
        description="Server instance handling this WebSocket connection")
    session_type: str = Field(nullable=False, index=True,
        description="Type of session: 'device' or 'web'")
    device_id: Optional[str] = Field(default=None, unique=True, index=True,
        description="Unique identifier (Mac device ID or browser session ID)")
    name: Optional[str] = Field(default=None,
        description="Display name (e.g., 'MacBook Pro' or 'Chrome')")
    last_heartbeat: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        description="Last activity - used to detect stale sessions")


class Home(SQLModel, table=True):
    """
    HomeKit homes tracked for MCP routing.

    When a Mac app connects and reports its homes, we cache the mapping
    so we can route MCP requests by home_id without requiring the JWT.
    """
    __tablename__ = "homes"

    home_id: uuid.UUID = Field(primary_key=True,
        description="Apple HomeKit home UUID")
    name: str = Field(nullable=False,
        description="Home name from HomeKit")
    user_id: uuid.UUID = Field(nullable=False, foreign_key="users.id", index=True,
        description="User who owns this home")
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        description="Last time this home was reported by device")


class StoredEntity(BaseModel, table=True):
    """
    Generic entity storage for all entity types.

    Stores JSON blobs for flexibility - can hold any entity data and layout config.

    Entity types:
    - 'home': HomeKit home (parent_id=null)
    - 'room': HomeKit room (parent_id=home_id)
    - 'collection': User-created collection (parent_id=null or home_id)
    - 'collection_group': Group within a collection (parent_id=collection_id)
    """
    __tablename__ = "stored_entities"

    owner_id: uuid.UUID = Field(nullable=False, foreign_key="users.id", index=True)
    entity_type: str = Field(nullable=False, index=True,
        description="Type: 'home', 'room', 'collection', 'collection_group'")
    entity_id: str = Field(nullable=False, index=True,
        description="UUID for the entity")
    parent_id: Optional[str] = Field(default=None, index=True,
        description="Parent entity ID (home_id for rooms, collection_id for groups)")

    # JSON blob storage
    data_json: str = Field(default="{}",
        description="Entity data (name, items, metadata)")
    layout_json: str = Field(default="{}",
        description="Layout config (ordering, visibility, display settings)")

    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc))


class EntityAccess(GraphQLBaseModel, table=True):
    """
    Unified access control for all entity types (collections, rooms, groups, homes, accessories).

    Three access types:
    - "public": Anyone with the link can access (role determines permission level)
    - "passcode": Requires passcode validation (additive on top of public)
    - "user": Specific user access (requires authentication)
    """
    __tablename__ = "entity_access"

    # Entity reference (polymorphic)
    entity_type: str = Field(nullable=False, index=True,
        description="Type: 'collection', 'room', 'group', 'home', 'accessory'")
    entity_id: uuid.UUID = Field(nullable=False, index=True,
        description="ID of the shared entity")
    home_id: Optional[uuid.UUID] = Field(default=None, index=True,
        description="Required for room/group/accessory (for ownership validation)")
    owner_id: uuid.UUID = Field(nullable=False, foreign_key="users.id", index=True,
        description="User who owns/created this share")

    # Access type (determines how this access works)
    access_type: str = Field(nullable=False, index=True,
        description="Type: 'public', 'passcode', or 'user'")

    # For access_type="user"
    user_id: Optional[uuid.UUID] = Field(default=None, foreign_key="users.id", index=True,
        description="Specific user granted access (for access_type='user')")

    # For access_type="passcode"
    passcode_hash: Optional[str] = Field(default=None,
        description="Hashed passcode (for access_type='passcode')")
    name: Optional[str] = Field(default=None,
        description="Label for passcode (e.g., 'Guest Access')")

    # Common fields
    role: str = Field(default="view",
        description="Permission level: 'view' or 'control'")
    access_schedule: Optional[str] = Field(default=None,
        description="JSON schedule config with expires_at, time_windows, timezone")


class SystemLog(BaseModel, table=True):
    """
    Unified system logs with distributed tracing support.

    Used for admin panel debugging, command tracking, and connectivity analysis.
    Logs can be grouped by trace_id to reconstruct the full request flow.
    """
    __tablename__ = "system_logs"

    # Log classification
    level: str = Field(nullable=False, index=True)  # debug, info, warning, error
    source: str = Field(nullable=False, index=True)  # api, websocket, pubsub, relay, homekit, auth

    # Message
    message: str = Field(nullable=False)

    # Context (optional)
    user_id: Optional[uuid.UUID] = Field(default=None, foreign_key="users.id", index=True)
    device_id: Optional[str] = Field(default=None, index=True)

    # Tracing (optional - links logs into traces)
    trace_id: Optional[str] = Field(default=None, index=True)  # Groups logs for same request
    span_name: Optional[str] = Field(default=None)  # Hop identifier: 'client', 'server', 'pubsub', 'relay', 'homekit'

    # For command logs
    action: Optional[str] = Field(default=None, index=True)  # 'set_characteristic', 'execute_scene'
    accessory_id: Optional[str] = Field(default=None, index=True)
    accessory_name: Optional[str] = Field(default=None)
    characteristic_type: Optional[str] = Field(default=None)
    value: Optional[str] = Field(default=None)
    success: Optional[bool] = Field(default=None, index=True)
    error: Optional[str] = Field(default=None)
    latency_ms: Optional[int] = Field(default=None)  # Time since trace started

    # Extended metadata
    metadata_json: Optional[str] = Field(default=None)  # JSON for extra data


__all__ = [
    "BaseModel",
    "GraphQLBaseModel",
    "User",
    "TopicSlot",
    "Session",
    "SessionType",
    "Home",
    "StoredEntity",
    "EntityAccess",
    "SystemLog",
]
