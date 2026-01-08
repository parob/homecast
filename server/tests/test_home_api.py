"""
Unit tests for HomeAPI.

Tests the simplified, AI-friendly HomeKit interface using sample_home.json.
"""

import json
import pytest
from pathlib import Path

from homecast.api.home import (
    _sanitize_name,
    _get_simple_name,
    _parse_value,
    _format_value,
    _get_device_type,
    _simplify_accessory,
    CHAR_TO_SIMPLE,
)


@pytest.fixture
def sample_home():
    """Load sample home data."""
    path = Path(__file__).parent / "sample_home.json"
    with open(path) as f:
        data = json.load(f)
    return data["data"]["accessories"]


class TestSanitizeName:
    def test_spaces_to_underscores(self):
        assert _sanitize_name("Living Room") == "Living_Room"

    def test_multiple_spaces(self):
        assert _sanitize_name("Living   Room") == "Living_Room"


class TestGetSimpleName:
    def test_power_state(self):
        assert _get_simple_name("power_state") == "on"

    def test_brightness(self):
        assert _get_simple_name("brightness") == "brightness"

    def test_current_temperature(self):
        assert _get_simple_name("current_temperature") == "current_temp"

    def test_skip_manufacturer(self):
        assert _get_simple_name("manufacturer") is None

    def test_skip_unknown_uuid(self):
        assert _get_simple_name("23B88013-D5E2-5300-9DF1-D51D90CADED9") is None

    def test_known_uuid(self):
        assert _get_simple_name("000000B1-0000-1000-8000-0026BB765291") == "current_heater_state"

    def test_passthrough_unknown(self):
        # Unknown but potentially useful characteristics pass through
        assert _get_simple_name("some_new_type") == "some_new_type"


class TestParseValue:
    def test_boolean_true(self):
        assert _parse_value("true", "power_state") is True

    def test_boolean_false(self):
        assert _parse_value("false", "active") is False

    def test_integer(self):
        assert _parse_value("73", "brightness") == 73

    def test_float(self):
        assert _parse_value("14.77", "current_temperature") == 14.8

    def test_quoted_string(self):
        assert _parse_value('"tado\\u00b0 GmbH"', "manufacturer") == "tado° GmbH"

    def test_null(self):
        assert _parse_value(None, "name") is None


class TestFormatValue:
    def test_boolean_on(self):
        assert _format_value(True, "on") is True
        assert _format_value(1, "on") is True
        assert _format_value(0, "on") is False

    def test_brightness(self):
        assert _format_value(73, "brightness") == 73
        assert _format_value(73.5, "brightness") == 73

    def test_temperature(self):
        assert _format_value(14.77, "current_temp") == 14.8
        assert _format_value(20, "heat_target") == 20.0

    def test_alarm_state(self):
        assert _format_value(0, "alarm_state") == "home"
        assert _format_value(1, "alarm_state") == "away"
        assert _format_value(2, "alarm_state") == "night"
        assert _format_value(3, "alarm_state") == "off"
        assert _format_value(4, "alarm_state") == "triggered"

    def test_locked(self):
        assert _format_value(1, "locked") is True
        assert _format_value(0, "locked") is False


class TestGetDeviceType:
    def test_lightbulb(self):
        acc = {"services": [{"serviceType": "lightbulb"}], "category": ""}
        assert _get_device_type(acc) == "light"

    def test_heater_cooler(self):
        acc = {"services": [{"serviceType": "heater_cooler"}], "category": "Thermostat"}
        assert _get_device_type(acc) == "climate"

    def test_security_system(self):
        acc = {"services": [{"serviceType": "security_system"}], "category": ""}
        assert _get_device_type(acc) == "alarm"

    def test_outlet(self):
        acc = {"services": [{"serviceType": "outlet"}], "category": "Outlet"}
        assert _get_device_type(acc) == "outlet"

    def test_lock(self):
        acc = {"services": [{"serviceType": "lock"}], "category": ""}
        assert _get_device_type(acc) == "lock"

    def test_motion_sensor(self):
        acc = {"services": [{"serviceType": "motion_sensor"}], "category": ""}
        assert _get_device_type(acc) == "motion"


class TestSimplifyAccessory:
    def test_light(self):
        acc = {
            "name": "Hue Adore Spot",
            "category": "Other",
            "services": [{
                "serviceType": "lightbulb",
                "characteristics": [
                    {"characteristicType": "power_state", "value": "false", "isWritable": True, "isReadable": True},
                    {"characteristicType": "brightness", "value": "73", "isWritable": True, "isReadable": True},
                    {"characteristicType": "color_temperature", "value": "369", "isWritable": True, "isReadable": True},
                ]
            }]
        }
        result = _simplify_accessory(acc)
        assert result["type"] == "light"
        assert result["on"] is False
        assert result["brightness"] == 73
        assert result["color_temp"] == 369
        assert set(result["_settable"]) == {"on", "brightness", "color_temp"}

    def test_climate(self):
        acc = {
            "name": "Living Room Thermostat",
            "category": "Thermostat",
            "services": [
                {
                    "serviceType": "heater_cooler",
                    "characteristics": [
                        {"characteristicType": "active", "value": "false", "isWritable": True, "isReadable": True},
                        {"characteristicType": "current_temperature", "value": "17.75", "isWritable": False, "isReadable": True},
                        {"characteristicType": "heating_threshold", "value": "20", "isWritable": True, "isReadable": True},
                    ]
                },
                {
                    "serviceType": "accessory_information",
                    "characteristics": [
                        {"characteristicType": "manufacturer", "value": '"tado"', "isWritable": False, "isReadable": True},
                    ]
                }
            ]
        }
        result = _simplify_accessory(acc)
        assert result["type"] == "climate"
        assert result["active"] is False
        assert result["current_temp"] == 17.8
        assert result["heat_target"] == 20.0
        assert "active" in result["_settable"]
        assert "heat_target" in result["_settable"]
        assert "current_temp" not in result["_settable"]  # Read-only
        assert "manufacturer" not in result  # Skipped

    def test_security_system(self):
        acc = {
            "name": "Alarm",
            "category": "",
            "services": [{
                "serviceType": "security_system",
                "characteristics": [
                    {"characteristicType": "security_system_current_state", "value": "1", "isWritable": False, "isReadable": True},
                    {"characteristicType": "security_system_target_state", "value": "3", "isWritable": True, "isReadable": True},
                ]
            }]
        }
        result = _simplify_accessory(acc)
        assert result["type"] == "alarm"
        assert result["alarm_state"] == "away"  # 1 = away
        assert result["alarm_target"] == "off"  # 3 = off
        assert "alarm_target" in result["_settable"]
        assert "alarm_state" not in result["_settable"]


class TestWithSampleData:
    """Test against real sample_home.json data."""

    def test_sample_data_loads(self, sample_home):
        assert len(sample_home) > 0

    def test_all_accessories_simplify(self, sample_home):
        """Ensure all accessories can be simplified without errors."""
        for acc in sample_home:
            result = _simplify_accessory(acc)
            assert "type" in result
            # Should have at least type
            assert isinstance(result["type"], str)

    def test_light_from_sample(self, sample_home):
        """Find a light and verify it simplifies correctly."""
        for acc in sample_home:
            services = [s.get("serviceType") for s in acc.get("services", [])]
            if "lightbulb" in services:
                result = _simplify_accessory(acc)
                assert result["type"] == "light"
                # Lights should have on/brightness
                if "on" in result:
                    assert isinstance(result["on"], bool)
                break

    def test_climate_from_sample(self, sample_home):
        """Find a climate device and verify it simplifies correctly."""
        for acc in sample_home:
            services = [s.get("serviceType") for s in acc.get("services", [])]
            if "heater_cooler" in services:
                result = _simplify_accessory(acc)
                assert result["type"] == "climate"
                # Climate should have temperature
                if "current_temp" in result:
                    assert isinstance(result["current_temp"], (int, float))
                break

    def test_settable_only_for_writable(self, sample_home):
        """Verify _settable only includes writable characteristics."""
        for acc in sample_home:
            result = _simplify_accessory(acc)
            if "_settable" in result:
                # Each settable should correspond to a writable characteristic
                for settable in result["_settable"]:
                    assert settable in result or settable in CHAR_TO_SIMPLE.values()

    def test_rooms_present(self, sample_home):
        """Verify room names are present."""
        rooms = set()
        for acc in sample_home:
            room = acc.get("roomName")
            if room:
                rooms.add(room)
        assert len(rooms) > 0
        # Sample should have multiple rooms
        assert "Living" in rooms or "Kitchen" in rooms or len(rooms) > 1

    def test_summary_output(self, sample_home):
        """Print a summary of what we'd output (for manual inspection)."""
        from collections import defaultdict
        rooms = defaultdict(dict)

        for acc in sample_home:
            room = _sanitize_name(acc.get("roomName", "Unknown"))
            name = _sanitize_name(acc.get("name", "Unknown"))
            simplified = _simplify_accessory(acc)
            rooms[room][name] = simplified

        # Print summary for first 3 rooms
        print("\n--- Sample Output Preview ---")
        for room, accessories in list(rooms.items())[:3]:
            print(f"\n{room}:")
            for name, data in list(accessories.items())[:3]:
                print(f"  {name}: {data}")
