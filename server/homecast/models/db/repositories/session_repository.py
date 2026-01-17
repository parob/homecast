"""
Repository for Session database operations.

Handles both device (Mac app) and web (browser) sessions.
"""

import uuid
import logging
from datetime import datetime, timezone, timedelta
from typing import List, Optional

from sqlmodel import Session as DBSession, select, delete

from homecast.models.db.models import Session, SessionType
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)

# Sessions older than this are considered stale
STALE_SESSION_TIMEOUT_SECONDS = 120  # 2 minutes


class SessionRepository(BaseRepository):
    """Repository for session operations."""

    MODEL_CLASS = Session

    # --- Create/Delete ---

    @classmethod
    def create_session(
        cls,
        db: DBSession,
        user_id: uuid.UUID,
        instance_id: str,
        session_type: SessionType,
        device_id: Optional[str] = None,
        name: Optional[str] = None
    ) -> Session:
        """Create a new session (or update existing for same device_id)."""
        # For device sessions, update existing if same device_id
        if device_id:
            existing = cls.get_device_session(db, device_id)
            if existing:
                existing.instance_id = instance_id
                existing.name = name or existing.name
                existing.last_heartbeat = datetime.now(timezone.utc)
                return cls.update(db, existing)

        session = Session(
            user_id=user_id,
            instance_id=instance_id,
            session_type=session_type.value,
            device_id=device_id,
            name=name,
            last_heartbeat=datetime.now(timezone.utc)
        )
        return cls.create(db, session)

    @classmethod
    def delete_session(cls, db: DBSession, session_id: uuid.UUID) -> bool:
        """Delete a session by ID."""
        session = db.get(Session, session_id)
        if not session:
            return False
        return cls.delete(db, session)

    @classmethod
    def delete_by_device_id(cls, db: DBSession, device_id: str) -> bool:
        """Delete session for a specific device."""
        statement = delete(Session).where(Session.device_id == device_id)
        db.exec(statement)
        db.commit()
        return True

    # --- Heartbeat ---

    @classmethod
    def update_heartbeat(cls, db: DBSession, session_id: uuid.UUID) -> Optional[Session]:
        """Update last_heartbeat for a session."""
        session = db.get(Session, session_id)
        if not session:
            return None
        session.last_heartbeat = datetime.now(timezone.utc)
        return cls.update(db, session)

    @classmethod
    def update_heartbeat_by_device(cls, db: DBSession, device_id: str, instance_id: Optional[str] = None) -> Optional[Session]:
        """Update last_heartbeat (and optionally instance_id) for a device session."""
        statement = select(Session).where(Session.device_id == device_id)
        session = db.exec(statement).first()
        if not session:
            return None
        session.last_heartbeat = datetime.now(timezone.utc)
        if instance_id and session.instance_id != instance_id:
            logger.info(f"Device {device_id} moved from instance {session.instance_id} to {instance_id}")
            session.instance_id = instance_id
        return cls.update(db, session)

    @classmethod
    def invalidate_instance_for_device(cls, db: DBSession, device_id: str, stale_instance_id: str) -> bool:
        """
        Clear instance_id for a device session if it matches the stale value.

        Called when a remote instance reports DEVICE_NOT_HERE - the session's
        instance_id is stale and should be cleared so routing can find the
        device's actual location.

        Returns True if the session was invalidated, False otherwise.
        """
        statement = select(Session).where(Session.device_id == device_id)
        session = db.exec(statement).first()
        if not session:
            return False
        # Only clear if it matches the stale instance (avoid race with device reconnecting)
        if session.instance_id == stale_instance_id:
            logger.info(f"Invalidating stale instance_id {stale_instance_id} for device {device_id}")
            session.instance_id = None
            cls.update(db, session)
            return True
        return False

    # --- Queries ---

    @classmethod
    def has_web_listeners(cls, db: DBSession, user_id: uuid.UUID) -> bool:
        """Check if a user has any active web sessions."""
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
        statement = (
            select(Session)
            .where(Session.user_id == user_id)
            .where(Session.session_type == SessionType.WEB.value)
            .where(Session.last_heartbeat > cutoff)
            .limit(1)
        )
        return db.exec(statement).first() is not None

    @classmethod
    def get_device_session(cls, db: DBSession, device_id: str, include_stale: bool = True) -> Optional[Session]:
        """Get the session for a device."""
        statement = select(Session).where(Session.device_id == device_id)
        if not include_stale:
            cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
            statement = statement.where(Session.last_heartbeat > cutoff)
        return db.exec(statement).first()

    @classmethod
    def get_user_device_session(cls, db: DBSession, user_id: uuid.UUID) -> Optional[Session]:
        """Get first active device session for a user."""
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
        statement = (
            select(Session)
            .where(Session.user_id == user_id)
            .where(Session.session_type == SessionType.DEVICE.value)
            .where(Session.last_heartbeat > cutoff)
            .limit(1)
        )
        return db.exec(statement).first()

    @classmethod
    def get_user_sessions(
        cls,
        db: DBSession,
        user_id: uuid.UUID,
        session_type: Optional[SessionType] = None
    ) -> List[Session]:
        """Get all active sessions for a user, optionally filtered by type."""
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
        statement = (
            select(Session)
            .where(Session.user_id == user_id)
            .where(Session.last_heartbeat > cutoff)
        )
        if session_type:
            statement = statement.where(Session.session_type == session_type.value)
        return list(db.exec(statement).all())

    @classmethod
    def get_web_client_instance_ids(
        cls,
        db: DBSession,
        user_id: uuid.UUID
    ) -> List[str]:
        """Get distinct instance_ids for all active web sessions for a user."""
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
        statement = (
            select(Session.instance_id)
            .where(Session.user_id == user_id)
            .where(Session.session_type == SessionType.WEB.value)
            .where(Session.last_heartbeat > cutoff)
            .distinct()
        )
        return list(db.exec(statement).all())

    # --- Cleanup ---

    @classmethod
    def cleanup_stale_sessions(cls, db: DBSession) -> int:
        """Delete sessions that haven't sent a heartbeat recently."""
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=STALE_SESSION_TIMEOUT_SECONDS)
        statement = delete(Session).where(Session.last_heartbeat < cutoff)
        result = db.exec(statement)
        db.commit()
        deleted_count = result.rowcount if hasattr(result, 'rowcount') else 0
        if deleted_count > 0:
            logger.info(f"Cleaned up {deleted_count} stale sessions")
        return deleted_count

    @classmethod
    def cleanup_instance_sessions(cls, db: DBSession, instance_id: str) -> int:
        """Delete all sessions for a specific instance (on shutdown)."""
        statement = delete(Session).where(Session.instance_id == instance_id)
        result = db.exec(statement)
        db.commit()
        deleted_count = result.rowcount if hasattr(result, 'rowcount') else 0
        if deleted_count > 0:
            logger.info(f"Cleaned up {deleted_count} sessions for instance {instance_id}")
        return deleted_count
