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


class Collection(GraphQLBaseModel, table=True):
    """
    A collection of HomeKit accessories that can be shared.
    """
    __tablename__ = "collections"

    name: str = Field(nullable=False,
        description="Display name for the collection")
    payload: str = Field(default="[]",
        description='JSON array: [{"home_id": "uuid", "accessory_id": "uuid"}, ...]')
    settings_json: Optional[str] = Field(default=None,
        description='JSON settings: {"compactMode": bool, "order": ["id1", "id2", ...]}')


class CollectionAccess(GraphQLBaseModel, table=True):
    """
    Access control for collections. Handles both user ownership and public shares.

    Two modes:
    - User access: user_id is set, role determines permission level
    - Public share: user_id is null, optional passcode_hash and access_schedule
    """
    __tablename__ = "collection_access"

    collection_id: uuid.UUID = Field(nullable=False, foreign_key="collections.id", index=True,
        description="The collection this access record belongs to")
    user_id: Optional[uuid.UUID] = Field(default=None, foreign_key="users.id", index=True,
        description="User who has access (null for public shares)")
    role: str = Field(default="view",
        description="Access level: 'owner', 'control', or 'view'")
    passcode_hash: Optional[str] = Field(default=None,
        description="Hashed passcode for public shares (null = no passcode required)")
    access_schedule: Optional[str] = Field(default=None,
        description="JSON schedule config with expires_at, time_windows, timezone")


__all__ = [
    "BaseModel",
    "GraphQLBaseModel",
    "User",
    "TopicSlot",
    "Session",
    "SessionType",
    "Home",
    "Collection",
    "CollectionAccess",
]
