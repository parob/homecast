"""
HomesAPI for HomeCast.

Provides a unified interface for controlling all homes belonging to a user.
Endpoint: /homes/{user_id}/

Tools:
- get_state(filter_by_home?, filter_by_room?, filter_by_type?, filter_by_name?) - Get state across all homes
- set_state(state) - Set state with homes at top level
- run_scene(home, name) - Run scene in a specific home
"""

import logging
import re
from contextvars import ContextVar
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional

from graphql_api import field

from homecast.models.db.database import get_session
from homecast.models.db.repositories import HomeRepository, UserRepository
from homecast.websocket.handler import route_request, get_user_device_id
from homecast.api.home import (
    _sanitize_name,
    _unique_key,
    _room_key,
    _accessory_key,
    _group_key,
    _simplify_accessory,
    HomeNotFoundError,
    DeviceNotConnectedError,
)

logger = logging.getLogger(__name__)

# Context variable for the current user_id (8-char prefix, lowercase)
_user_id_var: ContextVar[Optional[str]] = ContextVar("user_id", default=None)


def get_user_id() -> Optional[str]:
    """Get the current user_id from context."""
    return _user_id_var.get()


def set_user_id(user_id: Optional[str]):
    """Set the user_id in context."""
    _user_id_var.set(user_id)


def _home_key(name: str, home_id: str) -> str:
    """Generate unique home key: sanitized_name_shortid."""
    return _unique_key(name, home_id)


def _require_user_id() -> str:
    """Get user_id from context or raise error."""
    user_id = get_user_id()
    if not user_id:
        raise ValueError("No user_id in context")
    return user_id


async def _get_user_homes(user_id_prefix: str) -> List[Dict[str, Any]]:
    """Get all homes for a user with their device connections."""
    with get_session() as db:
        user = UserRepository.get_by_prefix(db, user_id_prefix)
        if not user:
            raise ValueError(f"Unknown user: {user_id_prefix}")

        homes = HomeRepository.get_by_user(db, user.id)
        result = []

        for home in homes:
            home_id_str = str(home.home_id)
            device_id = await get_user_device_id(user.id)
            result.append({
                "home_id": home_id_str,
                "home_key": _home_key(home.name, home_id_str),
                "name": home.name,
                "device_id": device_id,
                "user_id": user.id,
            })

        return result


# --- HomesAPI ---

class HomesAPI:
    """
    Unified API for controlling all homes belonging to a user.

    All responses have homes at the top level, making it easy to manage multiple homes.
    """

    @field
    async def get_state(
        self,
        filter_by_home: Optional[str] = None,
        filter_by_room: Optional[str] = None,
        filter_by_type: Optional[str] = None,
        filter_by_name: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Get the current state of all homes.

        Args:
            filter_by_home: Optional home key substring to filter (e.g. "beach" matches "beach_house_0bf8")
            filter_by_room: Optional room name substring to filter (e.g. "living" matches "living_0bf8")
            filter_by_type: Optional accessory type to filter (e.g. "light", "climate", "switch", "lock")
            filter_by_name: Optional accessory name substring to filter (e.g. "lamp" matches "hue_lamp_a1b2")

        All filters are case-insensitive and use substring matching. Multiple filters are AND'd together.

        Returns:
            Dictionary with home keys at top level, containing rooms, accessories and their states.
            All keys include a _xxxx ID suffix for uniqueness.

        Example response:
            {
              "my_house_0bf8": {
                "living_a1b2": {
                  "ceiling_light_c3d4": {"type": "light", "on": true, "brightness": 80, "_settable": ["on", "brightness"]}
                }
              },
              "beach_house_1c2d": {
                "bedroom_e5f6": {
                  "fan_7890": {"type": "fan", "on": false, "_settable": ["on", "speed"]}
                }
              },
              "_meta": {"fetched_at": "2024-01-09T12:34:56+00:00"}
            }
        """
        user_id_prefix = _require_user_id()
        homes = await _get_user_homes(user_id_prefix)

        # Load visibility settings for filtering (all homes belong to same user)
        from homecast.api.visibility import (
            get_server_visibility, is_home_hidden, is_room_hidden,
            is_device_hidden, is_group_hidden
        )
        visibility = get_server_visibility(homes[0]["user_id"]) if homes else None

        # Normalize filters
        home_filter = filter_by_home.lower() if filter_by_home else None
        room_filter = filter_by_room.lower() if filter_by_room else None
        type_filter = filter_by_type.lower() if filter_by_type else None
        name_filter = filter_by_name.lower() if filter_by_name else None

        result: Dict[str, Any] = {}

        for home_info in homes:
            home_key = home_info["home_key"]
            device_id = home_info["device_id"]
            full_home_id = home_info["home_id"]

            # Skip hidden homes
            if visibility and is_home_hidden(visibility, full_home_id):
                continue

            # Apply home filter
            if home_filter and home_filter not in home_key:
                continue

            if not device_id:
                # Home's device not connected, skip
                continue

            # Fetch accessories
            try:
                accessories_result = await route_request(
                    device_id=device_id,
                    action="accessories.list",
                    payload={"homeId": full_home_id, "includeValues": True}
                )

                groups_result = await route_request(
                    device_id=device_id,
                    action="serviceGroups.list",
                    payload={"homeId": full_home_id}
                )
            except Exception as e:
                logger.warning(f"Failed to fetch state for home {home_key}: {e}")
                continue

            # Build accessory lookup
            accessory_by_id: Dict[str, Dict[str, Any]] = {}
            for acc in accessories_result.get("accessories", []):
                acc_id = acc.get("id")
                if acc_id:
                    accessory_by_id[acc_id] = acc

            # Build room structure for this home
            home_state: Dict[str, Any] = {}

            for accessory in accessories_result.get("accessories", []):
                room_name = accessory.get("roomName", "Unknown")
                room_id = accessory.get("roomId", "")
                acc_name = accessory.get("name", "Unknown")
                acc_id = accessory.get("id", "")

                room_key_str = _room_key(room_name, room_id)
                accessory_key_str = _accessory_key(acc_name, acc_id)
                simplified = _simplify_accessory(accessory)
                acc_type = simplified.get("type", "")

                # Apply visibility filtering (skip hidden rooms/devices)
                if visibility and is_room_hidden(visibility, full_home_id, room_id):
                    continue
                if visibility and is_device_hidden(visibility, full_home_id, room_id, acc_id):
                    continue

                # Apply filters
                if room_filter and room_filter not in room_key_str:
                    continue
                if type_filter and type_filter != acc_type:
                    continue
                if name_filter and name_filter not in accessory_key_str:
                    continue

                if room_key_str not in home_state:
                    home_state[room_key_str] = {}

                # Add fully qualified name: home.room.accessory
                simplified["name"] = f"{home_key}.{room_key_str}.{accessory_key_str}"
                home_state[room_key_str][accessory_key_str] = simplified

            # Add service groups
            for group in groups_result.get("serviceGroups", []):
                group_id = group.get("id", "")
                group_name = group.get("name", "Unknown")
                group_key_str = _group_key(group_name, group_id)
                member_ids = group.get("accessoryIds", [])

                # Skip hidden groups
                if visibility and is_group_hidden(visibility, full_home_id, group_id):
                    continue

                if member_ids:
                    first_member = accessory_by_id.get(member_ids[0])
                    if first_member:
                        room_name = first_member.get("roomName", "Unknown")
                        room_id = first_member.get("roomId", "")
                        room_key_str = _room_key(room_name, room_id)

                        # Skip if the room is hidden
                        if visibility and is_room_hidden(visibility, full_home_id, room_id):
                            continue

                        group_state = _simplify_accessory(first_member)
                        group_state["group"] = True
                        group_type = group_state.get("type", "")

                        # Apply filters
                        if room_filter and room_filter not in room_key_str:
                            continue
                        if type_filter and type_filter != group_type:
                            continue
                        if name_filter and name_filter not in group_key_str:
                            continue

                        if room_key_str not in home_state:
                            home_state[room_key_str] = {}

                        # Add fully qualified name for group: home.room.group
                        group_state["name"] = f"{home_key}.{room_key_str}.{group_key_str}"

                        # Add member accessories (filter out hidden members)
                        accessories_dict = {}
                        for acc_id in member_ids:
                            # Skip hidden devices
                            if visibility and is_device_hidden(visibility, full_home_id, room_id, acc_id):
                                continue
                            member = accessory_by_id.get(acc_id)
                            if member:
                                member_key = _accessory_key(member.get("name", "Unknown"), acc_id)
                                member_state = _simplify_accessory(member)
                                # Add fully qualified name for group member: home.room.group.accessory
                                member_state["name"] = f"{home_key}.{room_key_str}.{group_key_str}.{member_key}"
                                accessories_dict[member_key] = member_state
                        group_state["accessories"] = accessories_dict

                        home_state[room_key_str][group_key_str] = group_state

            # Only add home if it has content after filtering
            if home_state:
                result[home_key] = home_state

        # Add metadata
        fetched_at = datetime.now(timezone.utc).isoformat(timespec='seconds')
        result["_meta"] = {"fetched_at": fetched_at}

        return result

    @field(mutable=True)
    async def set_state(
        self,
        state: Dict[str, Dict[str, Dict[str, Dict[str, Any]]]]
    ) -> Dict[str, Any]:
        """
        Set the state of accessories across multiple homes.

        Args:
            state: Dictionary with home keys at top level, containing rooms, accessories/groups and values.

        Structure: {home_key: {room_key: {accessory_key: {property: value}}}}

        Settable properties by device type:
            light: on (bool), brightness (0-100), hue (0-360), saturation (0-100), color_temp (140-500)
            climate: active (bool), heat_target (temp), cool_target (temp), hvac_mode (auto/heat/cool)
            switch/outlet: on (bool)
            lock: lock_target (bool, true=lock)
            alarm: alarm_target (home/away/night/off)
            fan: on (bool), speed (0-100)
            speaker: volume (0-100), mute (bool)
            blind: target (0-100 position)
            valve: active (bool)

        Groups (identified by "group": true in get_state):
            - Setting a group affects ALL accessories in that group
            - Individual accessories can still be controlled directly by their key

        Current state (includes _meta.fetched_at UTC - if within 10s or current time unknown, no need to call get_state):
        __HOMECAST_HOMES_STATE__

        Examples (keys must match exactly as shown in current state, including the _xxxx ID suffix):
            Single home: {"my_house_0bf8": {"living_a1b2": {"lamp_c3d4": {"on": true}}}}
            Multiple homes: {"house_0bf8": {"living_a1b2": {"lamp_c3d4": {"on": true}}}, "cabin_1c2d": {"den_e5f6": {"light_7890": {"on": false}}}}

        Returns:
            {"ok": 2, "failed": []} on success
        """
        user_id_prefix = _require_user_id()
        homes = await _get_user_homes(user_id_prefix)

        # Build home_key -> home_info lookup
        home_lookup = {h["home_key"]: h for h in homes}

        total_ok = 0
        all_failed = []

        for home_key, home_state in state.items():
            if home_key.startswith("_"):
                continue  # Skip metadata keys

            home_info = home_lookup.get(home_key)
            if not home_info:
                all_failed.append(f"{home_key}: home not found")
                continue

            device_id = home_info["device_id"]
            if not device_id:
                all_failed.append(f"{home_key}: device not connected")
                continue

            full_home_id = home_info["home_id"]

            try:
                result = await route_request(
                    device_id=device_id,
                    action="state.set",
                    payload={
                        "homeId": full_home_id,
                        "state": home_state
                    }
                )

                total_ok += result.get("ok", 0)
                failed = result.get("failed", [])
                # Prefix failures with home_key for clarity
                all_failed.extend([f"{home_key}/{f}" for f in failed])

            except Exception as e:
                logger.warning(f"Failed to set state for home {home_key}: {e}")
                all_failed.append(f"{home_key}: {str(e)}")

        return {"ok": total_ok, "failed": all_failed}

    @field(mutable=True)
    async def run_scene(self, home: str, name: str) -> Dict[str, Any]:
        """
        Execute a scene by name in a specific home.

        Args:
            home: The home key (e.g. "my_house_0bf8") - required
            name: Scene name to execute (e.g. "Good Morning")

        Returns:
            {"success": true} on success, {"error": "message"} on failure
        """
        user_id_prefix = _require_user_id()
        homes = await _get_user_homes(user_id_prefix)

        # Find the home
        home_info = None
        for h in homes:
            if h["home_key"] == home:
                home_info = h
                break

        if not home_info:
            return {"error": f"Home not found: {home}"}

        device_id = home_info["device_id"]
        if not device_id:
            return {"error": f"Device not connected for home: {home}"}

        full_home_id = home_info["home_id"]

        try:
            # Get scenes to find the one matching name
            scenes_result = await route_request(
                device_id=device_id,
                action="scenes.list",
                payload={"homeId": full_home_id}
            )

            scene_id = None
            for scene in scenes_result.get("scenes", []):
                if scene.get("name", "").lower() == name.lower():
                    scene_id = scene.get("id")
                    break

            if not scene_id:
                available = [s.get("name") for s in scenes_result.get("scenes", [])]
                return {"error": f"Scene '{name}' not found. Available: {available}"}

            # Execute the scene
            await route_request(
                device_id=device_id,
                action="scene.execute",
                payload={"homeId": full_home_id, "sceneId": scene_id}
            )

            return {"success": True}

        except Exception as e:
            logger.warning(f"Failed to run scene {name} in {home}: {e}")
            return {"error": str(e)}
