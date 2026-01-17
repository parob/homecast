"""
Repository for admin panel database operations.

Provides methods for user management, system logging, and diagnostics.
"""

import json
import uuid
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional, Tuple, List, Dict, Any

from sqlmodel import Session, select, func, desc, or_

from homecast.models.db.models import User, SystemLog, Session as DBSession, SessionType, Home
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


class AdminRepository(BaseRepository):
    """Repository for admin operations."""

    MODEL_CLASS = SystemLog

    # --- User Management ---

    @classmethod
    def get_all_users(
        cls,
        session: Session,
        limit: int = 50,
        offset: int = 0,
        search: Optional[str] = None
    ) -> Tuple[List[Dict[str, Any]], int]:
        """
        Get all users with pagination and optional search.

        Returns a tuple of (users_with_counts, total_count).
        """
        # Build base query
        query = select(User)

        if search:
            search_pattern = f"%{search}%"
            query = query.where(
                or_(
                    User.email.ilike(search_pattern),
                    User.name.ilike(search_pattern)
                )
            )

        # Get total count
        count_query = select(func.count()).select_from(query.subquery())
        total_count = session.exec(count_query).one()

        # Get paginated users
        query = query.order_by(desc(User.created_at)).offset(offset).limit(limit)
        users = session.exec(query).all()

        # Get device and home counts for each user
        result = []
        for user in users:
            # Count devices (sessions)
            device_count = session.exec(
                select(func.count())
                .select_from(DBSession)
                .where(DBSession.user_id == user.id)
                .where(DBSession.session_type == SessionType.DEVICE.value)
            ).one()

            # Count homes
            home_count = session.exec(
                select(func.count())
                .select_from(Home)
                .where(Home.user_id == user.id)
            ).one()

            result.append({
                "id": str(user.id),
                "email": user.email,
                "name": user.name,
                "created_at": user.created_at.isoformat() if user.created_at else None,
                "last_login_at": user.last_login_at.isoformat() if user.last_login_at else None,
                "is_active": user.is_active,
                "is_admin": user.is_admin,
                "device_count": device_count,
                "home_count": home_count,
            })

        return result, total_count

    @classmethod
    def get_user_with_details(
        cls,
        session: Session,
        user_id: uuid.UUID
    ) -> Optional[Dict[str, Any]]:
        """Get detailed user information including devices and homes."""
        user = session.get(User, user_id)
        if not user:
            return None

        # Get devices (sessions)
        devices = session.exec(
            select(DBSession)
            .where(DBSession.user_id == user_id)
        ).all()

        device_list = [
            {
                "id": str(d.id),
                "device_id": d.device_id,
                "name": d.name,
                "session_type": d.session_type,
                "last_seen_at": d.last_heartbeat.isoformat() if d.last_heartbeat else None,
            }
            for d in devices
        ]

        # Get homes
        homes = session.exec(
            select(Home)
            .where(Home.user_id == user_id)
        ).all()

        home_list = [
            {
                "id": str(h.home_id),
                "name": h.name,
            }
            for h in homes
        ]

        return {
            "id": str(user.id),
            "email": user.email,
            "name": user.name,
            "created_at": user.created_at.isoformat() if user.created_at else None,
            "last_login_at": user.last_login_at.isoformat() if user.last_login_at else None,
            "is_active": user.is_active,
            "is_admin": user.is_admin,
            "devices": device_list,
            "homes": home_list,
            "settings_json": user.settings_json,
        }

    @classmethod
    def toggle_user_active(
        cls,
        session: Session,
        user_id: uuid.UUID,
        is_active: bool
    ) -> bool:
        """Enable or disable a user account."""
        user = session.get(User, user_id)
        if not user:
            return False

        user.is_active = is_active
        session.add(user)
        session.commit()
        return True

    @classmethod
    def set_user_admin(
        cls,
        session: Session,
        user_id: uuid.UUID,
        is_admin: bool
    ) -> bool:
        """Promote or demote a user to/from admin."""
        user = session.get(User, user_id)
        if not user:
            return False

        user.is_admin = is_admin
        session.add(user)
        session.commit()
        return True

    # --- Logging ---

    @classmethod
    def create_log(
        cls,
        session: Session,
        level: str,
        source: str,
        message: str,
        user_id: Optional[uuid.UUID] = None,
        device_id: Optional[str] = None,
        trace_id: Optional[str] = None,
        span_name: Optional[str] = None,
        action: Optional[str] = None,
        accessory_id: Optional[str] = None,
        accessory_name: Optional[str] = None,
        characteristic_type: Optional[str] = None,
        value: Optional[str] = None,
        success: Optional[bool] = None,
        error: Optional[str] = None,
        latency_ms: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> SystemLog:
        """Create a new log entry."""
        log = SystemLog(
            level=level,
            source=source,
            message=message,
            user_id=user_id,
            device_id=device_id,
            trace_id=trace_id,
            span_name=span_name,
            action=action,
            accessory_id=accessory_id,
            accessory_name=accessory_name,
            characteristic_type=characteristic_type,
            value=value,
            success=success,
            error=error,
            latency_ms=latency_ms,
            metadata_json=json.dumps(metadata) if metadata else None,
        )
        session.add(log)
        session.commit()
        session.refresh(log)
        return log

    @classmethod
    def get_logs(
        cls,
        session: Session,
        level: Optional[str] = None,
        source: Optional[str] = None,
        user_id: Optional[uuid.UUID] = None,
        trace_id: Optional[str] = None,
        start_time: Optional[datetime] = None,
        end_time: Optional[datetime] = None,
        success: Optional[bool] = None,
        limit: int = 100,
        offset: int = 0
    ) -> Tuple[List[Dict[str, Any]], int]:
        """
        Get logs with filtering and pagination.

        Returns a tuple of (logs, total_count).
        """
        query = select(SystemLog)

        # Apply filters
        if level:
            query = query.where(SystemLog.level == level)
        if source:
            query = query.where(SystemLog.source == source)
        if user_id:
            query = query.where(SystemLog.user_id == user_id)
        if trace_id:
            query = query.where(SystemLog.trace_id == trace_id)
        if start_time:
            query = query.where(SystemLog.created_at >= start_time)
        if end_time:
            query = query.where(SystemLog.created_at <= end_time)
        if success is not None:
            query = query.where(SystemLog.success == success)

        # Get total count
        count_query = select(func.count()).select_from(query.subquery())
        total_count = session.exec(count_query).one()

        # Get paginated logs
        query = query.order_by(desc(SystemLog.created_at)).offset(offset).limit(limit)
        logs = session.exec(query).all()

        # Get user emails for logs that have user_id
        user_emails = {}
        user_ids = {log.user_id for log in logs if log.user_id}
        if user_ids:
            users = session.exec(
                select(User).where(User.id.in_(user_ids))
            ).all()
            user_emails = {user.id: user.email for user in users}

        result = []
        for log in logs:
            result.append({
                "id": str(log.id),
                "timestamp": log.created_at.isoformat() if log.created_at else None,
                "level": log.level,
                "source": log.source,
                "message": log.message,
                "user_id": str(log.user_id) if log.user_id else None,
                "user_email": user_emails.get(log.user_id) if log.user_id else None,
                "device_id": log.device_id,
                "trace_id": log.trace_id,
                "span_name": log.span_name,
                "action": log.action,
                "accessory_id": log.accessory_id,
                "accessory_name": log.accessory_name,
                "success": log.success,
                "error": log.error,
                "latency_ms": log.latency_ms,
                "metadata": log.metadata_json,
            })

        return result, total_count

    @classmethod
    def get_trace(
        cls,
        session: Session,
        trace_id: str
    ) -> List[Dict[str, Any]]:
        """Get all log entries for a trace, ordered by timestamp."""
        logs = session.exec(
            select(SystemLog)
            .where(SystemLog.trace_id == trace_id)
            .order_by(SystemLog.created_at)
        ).all()

        # Get user emails
        user_ids = {log.user_id for log in logs if log.user_id}
        user_emails = {}
        if user_ids:
            users = session.exec(
                select(User).where(User.id.in_(user_ids))
            ).all()
            user_emails = {user.id: user.email for user in users}

        result = []
        for log in logs:
            result.append({
                "id": str(log.id),
                "timestamp": log.created_at.isoformat() if log.created_at else None,
                "level": log.level,
                "source": log.source,
                "message": log.message,
                "user_id": str(log.user_id) if log.user_id else None,
                "user_email": user_emails.get(log.user_id) if log.user_id else None,
                "device_id": log.device_id,
                "trace_id": log.trace_id,
                "span_name": log.span_name,
                "action": log.action,
                "accessory_id": log.accessory_id,
                "accessory_name": log.accessory_name,
                "success": log.success,
                "error": log.error,
                "latency_ms": log.latency_ms,
                "metadata": log.metadata_json,
            })

        return result

    @classmethod
    def clear_logs(
        cls,
        session: Session,
        before_date: Optional[datetime] = None
    ) -> int:
        """Delete logs, optionally before a certain date. Returns count deleted."""
        from sqlmodel import delete

        stmt = delete(SystemLog)
        if before_date:
            stmt = stmt.where(SystemLog.created_at < before_date)

        result = session.exec(stmt)
        session.commit()
        return result.rowcount

    # --- Diagnostics ---

    @classmethod
    def get_system_diagnostics(
        cls,
        session: Session
    ) -> Dict[str, Any]:
        """Get system-wide diagnostics."""
        from homecast.models.db.models import TopicSlot

        # Count connections by type
        web_count = session.exec(
            select(func.count())
            .select_from(DBSession)
            .where(DBSession.session_type == SessionType.WEB.value)
        ).one()

        device_count = session.exec(
            select(func.count())
            .select_from(DBSession)
            .where(DBSession.session_type == SessionType.DEVICE.value)
        ).one()

        # Get active topic slots
        active_slots = session.exec(
            select(TopicSlot)
            .where(TopicSlot.instance_id != None)
        ).all()

        server_instances = [
            {
                "instance_id": slot.instance_id,
                "slot_name": slot.slot_name,
                "last_heartbeat": slot.last_heartbeat.isoformat() if slot.last_heartbeat else None,
            }
            for slot in active_slots
        ]

        # Get recent errors (last 24 hours)
        yesterday = datetime.now(timezone.utc) - timedelta(hours=24)
        recent_errors_data, _ = cls.get_logs(
            session,
            level="error",
            start_time=yesterday,
            limit=10
        )

        return {
            "server_instances": server_instances,
            "pubsub_enabled": len(active_slots) > 0,
            "pubsub_active_slots": len(active_slots),
            "total_websocket_connections": web_count + device_count,
            "web_connections": web_count,
            "device_connections": device_count,
            "recent_errors": recent_errors_data,
        }

    @classmethod
    def get_user_diagnostics(
        cls,
        session: Session,
        user_id: uuid.UUID
    ) -> Optional[Dict[str, Any]]:
        """Get diagnostics for a specific user."""
        user = session.get(User, user_id)
        if not user:
            return None

        # Get device session
        device_session = session.exec(
            select(DBSession)
            .where(DBSession.user_id == user_id)
            .where(DBSession.session_type == SessionType.DEVICE.value)
        ).first()

        # Get web sessions
        web_sessions = session.exec(
            select(DBSession)
            .where(DBSession.user_id == user_id)
            .where(DBSession.session_type == SessionType.WEB.value)
        ).all()

        # Determine routing mode
        routing_mode = "not_connected"
        if device_session:
            routing_mode = "local"  # Will be determined more accurately at runtime

        # Get recent commands for this user
        recent_commands, _ = cls.get_logs(
            session,
            user_id=user_id,
            source="api",
            limit=20
        )
        command_history = [
            {
                "timestamp": cmd["timestamp"],
                "action": cmd["action"],
                "accessory_id": cmd["accessory_id"],
                "accessory_name": cmd["accessory_name"],
                "success": cmd["success"],
                "latency_ms": cmd["latency_ms"],
                "error": cmd["error"],
            }
            for cmd in recent_commands
            if cmd["action"]  # Only include logs with actions
        ]

        # Get connection events
        connection_logs, _ = cls.get_logs(
            session,
            user_id=user_id,
            source="websocket",
            limit=20
        )
        connection_history = [
            {
                "timestamp": log["timestamp"],
                "event": log["message"],
                "details": log["metadata"],
            }
            for log in connection_logs
        ]

        return {
            "user_id": str(user_id),
            "user_email": user.email,
            "websocket_connected": len(web_sessions) > 0,
            "device_connected": device_session is not None,
            "routing_mode": routing_mode,
            "device_name": device_session.name if device_session else None,
            "device_last_seen": device_session.last_heartbeat.isoformat() if device_session and device_session.last_heartbeat else None,
            "recent_commands": command_history,
            "connection_history": connection_history,
        }

    @classmethod
    def force_disconnect_device(
        cls,
        session: Session,
        device_id: str
    ) -> bool:
        """Force disconnect a device by removing its session."""
        device_session = session.exec(
            select(DBSession)
            .where(DBSession.device_id == device_id)
        ).first()

        if not device_session:
            return False

        session.delete(device_session)
        session.commit()
        return True
