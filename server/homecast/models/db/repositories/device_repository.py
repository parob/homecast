"""
Repository for Device database operations.
"""

import uuid
import logging
from datetime import datetime, timezone
from typing import List, Optional

from sqlmodel import Session, select

from homecast.models.db.models import Device, DeviceStatus
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


class DeviceRepository(BaseRepository):
    """Repository for device operations."""

    MODEL_CLASS = Device

    @classmethod
    def find_by_device_id(
        cls,
        session: Session,
        device_id: str
    ) -> Optional[Device]:
        """Find a device by its unique device ID."""
        statement = select(Device).where(Device.device_id == device_id)
        return session.exec(statement).one_or_none()

    @classmethod
    def find_by_user(
        cls,
        session: Session,
        user_id: uuid.UUID
    ) -> List[Device]:
        """Find all devices belonging to a user."""
        statement = select(Device).where(Device.user_id == user_id)
        return list(session.exec(statement).all())

    @classmethod
    def register_device(
        cls,
        session: Session,
        user_id: uuid.UUID,
        device_id: str,
        name: str
    ) -> Device:
        """
        Register a new device or update existing one.

        Args:
            session: Database session
            user_id: Owner's user ID
            device_id: Unique device identifier
            name: Device display name

        Returns:
            Device instance
        """
        existing = cls.find_by_device_id(session, device_id)

        if existing:
            # Update existing device
            existing.user_id = user_id
            existing.name = name
            existing.status = DeviceStatus.CONNECTING.value
            return cls.update(session, existing)

        # Create new device
        device = Device(
            user_id=user_id,
            device_id=device_id,
            name=name,
            status=DeviceStatus.CONNECTING.value
        )
        return cls.create(session, device)

    @classmethod
    def set_online(
        cls,
        session: Session,
        device_id: str,
        home_count: int = 0,
        accessory_count: int = 0
    ) -> Optional[Device]:
        """Mark a device as online and update HomeKit stats."""
        device = cls.find_by_device_id(session, device_id)
        if not device:
            return None

        device.status = DeviceStatus.ONLINE.value
        device.last_seen_at = datetime.now(timezone.utc)
        device.home_count = home_count
        device.accessory_count = accessory_count

        return cls.update(session, device)

    @classmethod
    def set_offline(
        cls,
        session: Session,
        device_id: str
    ) -> Optional[Device]:
        """Mark a device as offline."""
        device = cls.find_by_device_id(session, device_id)
        if not device:
            return None

        device.status = DeviceStatus.OFFLINE.value
        return cls.update(session, device)

    @classmethod
    def get_online_devices(
        cls,
        session: Session,
        user_id: Optional[uuid.UUID] = None
    ) -> List[Device]:
        """Get all online devices, optionally filtered by user."""
        statement = select(Device).where(Device.status == DeviceStatus.ONLINE.value)

        if user_id:
            statement = statement.where(Device.user_id == user_id)

        return list(session.exec(statement).all())

    @classmethod
    def update_heartbeat(
        cls,
        session: Session,
        device_id: str
    ) -> Optional[Device]:
        """Update last_seen_at timestamp for heartbeat."""
        device = cls.find_by_device_id(session, device_id)
        if not device:
            return None

        device.last_seen_at = datetime.now(timezone.utc)
        return cls.update(session, device)

    @classmethod
    def delete_by_device_id(
        cls,
        session: Session,
        device_id: str
    ) -> bool:
        """Delete a device by its device ID."""
        device = cls.find_by_device_id(session, device_id)
        if not device:
            return False

        return cls.delete(session, device)
