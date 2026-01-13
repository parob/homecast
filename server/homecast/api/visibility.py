"""
Server visibility settings for filtering API responses.

Loads visibility configuration from user settings and provides helper functions
to check if homes, rooms, groups, or devices should be hidden from API responses.
"""

import json
import uuid
from typing import Dict, List
from dataclasses import dataclass, field

from homecast.models.db import get_session
from homecast.models.db.repositories.user_repository import UserRepository


@dataclass
class ServerVisibility:
    """Parsed server visibility settings."""
    hidden_homes: List[str] = field(default_factory=list)  # Full home UUIDs
    hidden_rooms: Dict[str, List[str]] = field(default_factory=dict)  # home_id -> room_ids
    hidden_groups: Dict[str, List[str]] = field(default_factory=dict)  # home_id -> group_ids
    hidden_devices: Dict[str, Dict[str, List[str]]] = field(default_factory=dict)  # home_id -> context_id -> device_ids


def get_server_visibility(user_id: uuid.UUID) -> ServerVisibility:
    """Load visibility settings for a user.

    Args:
        user_id: The user's UUID

    Returns:
        ServerVisibility with the user's hidden items, or empty defaults if none configured
    """
    with get_session() as session:
        settings_json = UserRepository.get_settings(session, user_id)

    if not settings_json:
        return ServerVisibility()

    try:
        settings = json.loads(settings_json)
        server = settings.get("visibility", {}).get("server", {})
        return ServerVisibility(
            hidden_homes=server.get("hiddenHomes", []),
            hidden_rooms=server.get("hiddenRooms", {}),
            hidden_groups=server.get("hiddenGroups", {}),
            hidden_devices=server.get("hiddenDevices", {}),
        )
    except (json.JSONDecodeError, TypeError):
        return ServerVisibility()


def is_home_hidden(vis: ServerVisibility, home_id: str) -> bool:
    """Check if a home is hidden."""
    return home_id in vis.hidden_homes


def is_room_hidden(vis: ServerVisibility, home_id: str, room_id: str) -> bool:
    """Check if a room is hidden.

    Cascading: If the home is hidden, all rooms in it are hidden.
    """
    if home_id in vis.hidden_homes:
        return True
    return room_id in vis.hidden_rooms.get(home_id, [])


def is_group_hidden(vis: ServerVisibility, home_id: str, group_id: str) -> bool:
    """Check if a service group is hidden.

    Cascading: If the home is hidden, all groups in it are hidden.
    """
    if home_id in vis.hidden_homes:
        return True
    return group_id in vis.hidden_groups.get(home_id, [])


def is_device_hidden(vis: ServerVisibility, home_id: str, room_id: str, device_id: str) -> bool:
    """Check if a device is hidden.

    Cascading:
    - If the home is hidden, all devices in it are hidden.
    - If the room is hidden, all devices in that room are hidden.
    """
    if home_id in vis.hidden_homes:
        return True
    if room_id in vis.hidden_rooms.get(home_id, []):
        return True
    return device_id in vis.hidden_devices.get(home_id, {}).get(room_id, [])
