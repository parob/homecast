"""
HomeAPI for HomeCast.

Provides a simplified, AI-friendly interface for controlling HomeKit devices.
Uses human-readable names and a symmetrical get/set structure.

Tools:
- get_state(rooms?) - Get home state. Empty = all rooms.
- set_state(state) - Set multiple accessories at once.
- run_scene(name) - Execute a scene by name.
"""

import json
import logging
import re
from contextvars import ContextVar
from typing import Dict, Any, List, Optional

from graphql_api import field

from homecast.models.db.database import get_session
from homecast.models.db.repositories import HomeRepository
from homecast.websocket.handler import route_request, get_user_device_id

logger = logging.getLogger(__name__)

# Context variable for the current home_id (8-char prefix, lowercase)
_home_id_var: ContextVar[Optional[str]] = ContextVar("home_id", default=None)


def get_home_id() -> Optional[str]:
    """Get the current home_id from context."""
    return _home_id_var.get()


def set_home_id(home_id: Optional[str]):
    """Set the home_id in context."""
    _home_id_var.set(home_id)


class HomeNotFoundError(Exception):
    pass


class DeviceNotConnectedError(Exception):
    pass


def _sanitize_name(name: str) -> str:
    """Convert accessory name to safe key format (spaces to underscores, lowercase)."""
    return re.sub(r'\s+', '_', name.strip()).lower()


# --- Characteristic Mapping ---
# Maps HomeKit characteristic types to simple names
# Format: characteristic_type -> simple_name
CHAR_TO_SIMPLE = {
    # Power/Active
    'power_state': 'on',
    'active': 'active',
    'status_active': 'status_active',

    # Light
    'brightness': 'brightness',
    'hue': 'hue',
    'saturation': 'saturation',
    'color_temperature': 'color_temp',

    # Climate
    'current_temperature': 'current_temp',
    'heating_threshold': 'heat_target',
    'cooling_threshold': 'cool_target',
    'target_temperature': 'target_temp',

    # Lock
    'lock_current_state': 'locked',
    'lock_target_state': 'lock_target',

    # Security
    'security_system_current_state': 'alarm_state',
    'security_system_target_state': 'alarm_target',

    # Sensors
    'motion_detected': 'motion',
    'contact_state': 'contact',
    'battery_level': 'battery',
    'status_low_battery': 'low_battery',

    # Audio
    'volume': 'volume',
    'mute': 'mute',
}

# Reverse mapping for setting values
SIMPLE_TO_CHAR = {v: k for k, v in CHAR_TO_SIMPLE.items()}

# Add UUID-based reverse mappings
SIMPLE_TO_CHAR['hvac_mode'] = '000000B2-0000-1000-8000-0026BB765291'

# Characteristics to skip (info only, not useful for control)
SKIP_CHARACTERISTICS = {
    'name', 'manufacturer', 'model', 'serial_number',
    'firmware_revision', 'hardware_revision', 'identify',
}

# UUID mappings for common HomeKit UUIDs
UUID_TO_SIMPLE = {
    '000000b1-0000-1000-8000-0026bb765291': 'hvac_state',   # current heater/cooler state
    '000000b2-0000-1000-8000-0026bb765291': 'hvac_mode',    # target heater/cooler state
}

# Service types to skip
SKIP_SERVICES = {'accessory_information', 'battery', 'label'}


def _get_simple_name(char_type: str) -> Optional[str]:
    """Convert characteristic type to simple name."""
    # Check direct mapping
    if char_type in CHAR_TO_SIMPLE:
        return CHAR_TO_SIMPLE[char_type]

    # Check UUID mapping
    lower = char_type.lower()
    if lower in UUID_TO_SIMPLE:
        return UUID_TO_SIMPLE[lower]

    # Skip known unimportant characteristics
    if char_type in SKIP_CHARACTERISTICS:
        return None

    # Skip UUIDs we don't recognize
    if '-' in char_type and len(char_type) > 20:
        return None

    # Return as-is for unknown but potentially useful characteristics
    return char_type


def _parse_value(value: Any, char_type: str) -> Any:
    """Parse characteristic value to appropriate Python type."""
    if value is None:
        return None

    # Handle string-encoded values
    if isinstance(value, str):
        # Try JSON parsing for quoted strings
        if value.startswith('"'):
            try:
                value = json.loads(value)
            except:
                pass

        # Parse booleans
        if value.lower() in ('true', 'false'):
            return value.lower() == 'true'

        # Parse numbers
        try:
            if '.' in value:
                return round(float(value), 1)
            return int(value)
        except:
            pass

    return value


def _format_value(value: Any, simple_name: str) -> Any:
    """Format value for output."""
    if value is None:
        return None

    # Alarm state - convert to readable string (check first before numeric handling)
    if simple_name == 'alarm_state':
        states = {0: 'home', 1: 'away', 2: 'night', 3: 'off', 4: 'triggered'}
        return states.get(int(value), f'unknown_{value}')

    if simple_name == 'alarm_target':
        states = {0: 'home', 1: 'away', 2: 'night', 3: 'off'}
        return states.get(int(value), f'unknown_{value}')

    # HVAC state - current heater/cooler state
    if simple_name == 'hvac_state':
        states = {0: 'inactive', 1: 'idle', 2: 'heating', 3: 'cooling'}
        return states.get(int(value), f'unknown_{value}')

    # HVAC mode - target heater/cooler state
    if simple_name == 'hvac_mode':
        states = {0: 'auto', 1: 'heat', 2: 'cool'}
        return states.get(int(value), f'unknown_{value}')

    # Lock state
    if simple_name == 'locked':
        # 0=unsecured, 1=secured, 2=jammed, 3=unknown
        return value == 1 if isinstance(value, (int, float)) else bool(value)

    # Boolean fields
    if simple_name in ('on', 'active', 'motion', 'mute', 'low_battery'):
        return bool(value)

    # Percentage fields (0-100)
    if simple_name in ('brightness', 'battery', 'volume'):
        return int(value) if value is not None else None

    # Temperature fields
    if 'temp' in simple_name or simple_name in ('heat_target', 'cool_target'):
        return round(float(value), 1) if value is not None else None

    return value


def _get_device_type(accessory: Dict) -> str:
    """Determine simplified device type from accessory."""
    services = [s.get('serviceType', '').lower() for s in accessory.get('services', [])]
    category = (accessory.get('category') or '').lower()

    # Check services first (more reliable)
    if 'lightbulb' in services:
        return 'light'
    if 'switch' in services:
        return 'switch'
    if 'outlet' in services:
        return 'outlet'
    if 'heater_cooler' in services or 'thermostat' in services:
        return 'climate'
    if 'lock' in services:
        return 'lock'
    if 'security_system' in services:
        return 'alarm'
    if 'motion_sensor' in services:
        return 'motion'
    if 'contact_sensor' in services:
        return 'contact'
    if 'temperature_sensor' in services:
        return 'temperature'
    if 'light_sensor' in services:
        return 'light_sensor'
    if 'doorbell' in services:
        return 'doorbell'
    if 'stateless_programmable_switch' in services:
        return 'button'
    if 'microphone' in services:
        return 'speaker'

    # Fall back to category
    if 'light' in category:
        return 'light'
    if 'thermostat' in category:
        return 'climate'
    if 'lock' in category:
        return 'lock'
    if 'outlet' in category:
        return 'outlet'
    if 'switch' in category:
        return 'switch'

    return 'other'


def _simplify_accessory(accessory: Dict) -> Dict[str, Any]:
    """Convert accessory to simplified format with _settable list."""
    result = {'type': _get_device_type(accessory)}
    settable = []

    for service in accessory.get('services', []):
        service_type = service.get('serviceType', '').lower()

        # Skip info/auxiliary services
        if service_type in SKIP_SERVICES:
            continue

        for char in service.get('characteristics', []):
            char_type = char.get('characteristicType', '')
            simple_name = _get_simple_name(char_type)

            if not simple_name:
                continue

            # Parse and format value
            raw_value = _parse_value(char.get('value'), char_type)
            formatted_value = _format_value(raw_value, simple_name)

            if formatted_value is not None:
                result[simple_name] = formatted_value

                # Track settable characteristics (only if we have a value)
                if char.get('isWritable') and simple_name not in settable:
                    settable.append(simple_name)

    if settable:
        result['_settable'] = settable

    return result


def _value_for_characteristic(simple_name: str, value: Any) -> tuple[str, Any]:
    """Convert simple name and value back to characteristic type and HomeKit value."""
    # Get characteristic type
    char_type = SIMPLE_TO_CHAR.get(simple_name, simple_name)

    # Convert value for HomeKit
    if simple_name in ('on', 'active', 'mute'):
        return char_type, bool(value)

    if simple_name in ('brightness', 'volume'):
        return char_type, int(value)

    if 'temp' in simple_name or 'target' in simple_name:
        return char_type, float(value)

    if simple_name == 'lock_target':
        # locked=True -> 1 (secured), locked=False -> 0 (unsecured)
        return char_type, 1 if value else 0

    if simple_name == 'alarm_target':
        # Convert string back to number
        states = {'home': 0, 'away': 1, 'night': 2, 'off': 3}
        return char_type, states.get(str(value).lower(), int(value) if isinstance(value, int) else 0)

    if simple_name == 'hvac_mode':
        # Convert string back to number
        states = {'auto': 0, 'heat': 1, 'cool': 2}
        return char_type, states.get(str(value).lower(), int(value) if isinstance(value, int) else 0)

    return char_type, value


async def _get_device_for_home(home_id_prefix: str) -> tuple[str, str]:
    """Look up device_id from home ownership."""
    with get_session() as db:
        home = HomeRepository.get_by_prefix(db, home_id_prefix)
        if not home:
            raise HomeNotFoundError(f"Unknown home: {home_id_prefix}")

        device_id = await get_user_device_id(home.user_id)
        if not device_id:
            raise DeviceNotConnectedError(f"No connected device for home {home_id_prefix}")

        return device_id, str(home.home_id)


def _require_home_id() -> str:
    """Get home_id from context or raise error."""
    home_id = get_home_id()
    if not home_id:
        raise ValueError("No home_id in context")
    return home_id


# --- HomeAPI ---

class HomeAPI:
    """
    Simplified API for AI-friendly HomeKit control.

    Uses human-readable names and includes _settable to indicate what can be changed.
    """

    @field
    async def get_state(self, rooms: Optional[List[str]] = None) -> Dict[str, Any]:
        """
        Get the current state of the home.

        Args:
            rooms: Optional list of room names to filter. If empty/None, returns all rooms.

        Returns:
            Dictionary with room names as keys, containing accessories and their states.
            Each accessory includes a _settable list of properties that can be changed.

        Example response:
            {
              "Living": {
                "Ceiling_Light": {"type": "light", "on": true, "brightness": 80, "_settable": ["on", "brightness"]},
                "Thermostat": {"type": "climate", "current_temp": 18.5, "heat_target": 21, "_settable": ["heat_target", "active"]}
              },
              "scenes": ["Good Morning", "Goodnight"]
            }
        """
        home_id_prefix = _require_home_id()
        device_id, full_home_id = await _get_device_for_home(home_id_prefix)

        # Get accessories with values
        accessories_result = await route_request(
            device_id=device_id,
            action="accessories.list",
            payload={"homeId": full_home_id, "includeValues": True}
        )

        # Get scenes
        scenes_result = await route_request(
            device_id=device_id,
            action="scenes.list",
            payload={"homeId": full_home_id}
        )

        # Get service groups (accessory groups)
        groups_result = await route_request(
            device_id=device_id,
            action="serviceGroups.list",
            payload={"homeId": full_home_id}
        )

        # Build accessory lookup by ID for group membership
        accessory_by_id: Dict[str, Dict[str, Any]] = {}
        for acc in accessories_result.get("accessories", []):
            acc_id = acc.get("id")
            if acc_id:
                accessory_by_id[acc_id] = acc

        # Build room-based structure
        result: Dict[str, Any] = {}
        rooms_filter = set(r.lower() for r in rooms) if rooms else None

        for accessory in accessories_result.get("accessories", []):
            room_name = accessory.get("roomName", "Unknown")

            # Filter by rooms if specified
            if rooms_filter and room_name.lower() not in rooms_filter:
                continue

            room_key = _sanitize_name(room_name)
            if room_key not in result:
                result[room_key] = {}

            accessory_name = accessory.get("name", "Unknown")
            accessory_key = _sanitize_name(accessory_name)

            result[room_key][accessory_key] = _simplify_accessory(accessory)

        # Add service groups in the room of their first member
        for group in groups_result.get("serviceGroups", []):
            group_name = _sanitize_name(group.get("name", "Unknown"))
            member_ids = group.get("accessoryIds", [])
            if member_ids:
                first_member = accessory_by_id.get(member_ids[0])
                if first_member:
                    room_name = first_member.get("roomName", "Unknown")
                    if rooms_filter and room_name.lower() not in rooms_filter:
                        continue
                    room_key = _sanitize_name(room_name)
                    if room_key not in result:
                        result[room_key] = {}

                    # Build group state from first member + accessories list
                    group_state = _simplify_accessory(first_member)
                    group_state["group"] = True

                    # Add all member accessories with their states
                    accessories_dict = {}
                    for acc_id in member_ids:
                        member = accessory_by_id.get(acc_id)
                        if member:
                            member_key = _sanitize_name(member.get("name", "Unknown"))
                            accessories_dict[member_key] = _simplify_accessory(member)
                    group_state["accessories"] = accessories_dict

                    result[room_key][group_name] = group_state

        # Add scenes
        result["scenes"] = [s.get("name") for s in scenes_result.get("scenes", [])]

        return result

    @field(mutable=True)
    async def set_state(
        self,
        state: Dict[str, Dict[str, Dict[str, Any]]]
    ) -> Dict[str, Any]:
        """
        Set the state of multiple accessories or groups.

        Args:
            state: Dictionary with room names as keys, containing accessories/groups and values to set.

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
            - Individual accessories can still be controlled directly by name
            - Example: "all_lights" group contains "lamp_1" and "lamp_2"
              - Turn off all: {"room": {"all_lights": {"on": false}}}
              - Turn off just lamp_1: {"room": {"lamp_1": {"on": false}}}

        Current state: __HOMECAST_STATE__

        Examples:
            Single accessory: {"living_room": {"ceiling_light": {"on": true, "brightness": 100}}}
            Whole group: {"living_room": {"all_lights": {"on": false}}}
            Multiple: {"living_room": {"lamp_1": {"on": true}, "lamp_2": {"on": false}}}

        Returns:
            {"ok": 2, "failed": []} on success
        """
        home_id_prefix = _require_home_id()
        device_id, full_home_id = await _get_device_for_home(home_id_prefix)

        logger.info(f"set_state called with: {state}")

        # Pass directly to app - it handles name->ID mapping locally
        result = await route_request(
            device_id=device_id,
            action="state.set",
            payload={
                "homeId": full_home_id,
                "state": state
            }
        )

        logger.info(f"set_state complete: {result}")
        return {"ok": result.get("ok", 0), "failed": result.get("failed", [])}

    @field(mutable=True)
    async def run_scene(self, name: str) -> Dict[str, Any]:
        """
        Execute a HomeKit scene by name.

        Args:
            name: The name of the scene to run (e.g., "Good Morning", "Goodnight")

        Returns:
            {"ok": true} on success, {"ok": false, "error": "message"} on failure
        """
        home_id_prefix = _require_home_id()
        device_id, full_home_id = await _get_device_for_home(home_id_prefix)

        # Get scenes to find ID by name
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
            return {"ok": False, "error": f"Scene '{name}' not found"}

        try:
            await route_request(
                device_id=device_id,
                action="scene.execute",
                payload={"sceneId": scene_id}
            )
            return {"ok": True}
        except Exception as e:
            return {"ok": False, "error": str(e)}
