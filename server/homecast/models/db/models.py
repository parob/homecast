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


class CollectionRole(str, Enum):
    """Role for collection access (both user and public shares)."""
    OWNER = "owner"      # Full control (edit, delete, share) - user access only
    CONTROL = "control"  # Can view and control accessories
    VIEW = "view"        # Read-only access


class Collection(BaseModel, table=True):
    """
    User-defined collection of HomeKit accessories.

    Collections can contain entire homes, rooms, or individual accessories.
    They can be shared publicly via a URL with optional password protection.
    """
    __tablename__ = "collections"

    name: str = Field(nullable=False,
        description="Collection name")
    items_json: str = Field(default="[]",
        description="JSON array of items: [{type, home_id, room_id?, accessory_id?}]")
    is_active: bool = Field(default=True)

    # Sharing settings
    is_shared: bool = Field(default=False,
        description="Whether collection is publicly accessible")
    share_token: Optional[str] = Field(default=None, unique=True, index=True,
        description="URL token for public access")
    share_access_level: Optional[str] = Field(default=None,
        description="ShareAccessLevel: view or control")
    share_password_hash: Optional[str] = Field(default=None,
        description="Hashed password for protected shares")
    share_expires_at: Optional[datetime] = Field(default=None,
        description="Optional expiration date for share")


class CollectionAccess(BaseModel, table=True):
    """
    Links users to collections with specific roles.

    Owner is the creator, viewers are users who saved the collection.
    """
    __tablename__ = "collection_access"

    user_id: uuid.UUID = Field(nullable=False, foreign_key="users.id", index=True)
    collection_id: uuid.UUID = Field(nullable=False, foreign_key="collections.id", index=True)
    role: str = Field(nullable=False,
        description="CollectionRole: owner, control, or view")


__all__ = [
    "BaseModel",
    "User",
    "TopicSlot",
    "Session",
    "SessionType",
    "Home",
    "CollectionRole",
    "Collection",
    "CollectionAccess",
]
