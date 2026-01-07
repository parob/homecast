"""
Admin GraphQL API - authentication required.

Endpoints for managing devices and user account.
"""

import logging
from typing import List, Optional
from dataclasses import dataclass

from graphql_api import field

from homekit_mcp.models.db.database import get_session
from homekit_mcp.models.db.models import DeviceStatus
from homekit_mcp.models.db.repositories import UserRepository, DeviceRepository
from homekit_mcp.middleware import get_auth_context

logger = logging.getLogger(__name__)


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


class AdminAPI:
    """Admin API endpoints - authentication required."""

    @field
    async def me(self) -> Optional[UserInfo]:
        """Get current user's account information."""
        auth = get_auth_context()
        if not auth:
            return None

        with get_session() as session:
            user = UserRepository.find_by_id(session, auth.user_id)
            if not user:
                return None

            return UserInfo(
                id=str(user.id),
                email=user.email,
                name=user.name,
                created_at=user.created_at.isoformat(),
                last_login_at=user.last_login_at.isoformat() if user.last_login_at else None
            )

    @field
    async def my_devices(self) -> List[DeviceInfo]:
        """Get all devices belonging to the current user."""
        auth = get_auth_context()
        if not auth:
            return []

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
        """Get a specific device by device_id."""
        auth = get_auth_context()
        if not auth:
            return None

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
        Register a new device or update an existing one.

        Args:
            device_id: Unique device identifier from the Mac app
            name: Display name for the device

        Returns:
            DeviceRegistration result
        """
        auth = get_auth_context()
        if not auth:
            return DeviceRegistration(success=False, error="Not authenticated")

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
        """Remove a device from the user's account."""
        auth = get_auth_context()
        if not auth:
            return False

        with get_session() as session:
            device = DeviceRepository.find_by_device_id(session, device_id)

            if not device or device.user_id != auth.user_id:
                return False

            return DeviceRepository.delete(session, device)

    @field
    async def online_devices(self) -> List[DeviceInfo]:
        """Get all online devices belonging to the current user."""
        auth = get_auth_context()
        if not auth:
            return []

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
