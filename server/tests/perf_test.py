"""
Performance test to identify bottlenecks in the accessories endpoint.

Tests:
1. JSON parsing of stringified accessories
2. graphql-api serialization
3. Full end-to-end request
"""

import asyncio
import json
import time
import uuid
from typing import List, Dict, Any

# Generate fake accessory data similar to real HomeKit data
def generate_fake_accessory(index: int) -> Dict[str, Any]:
    """Generate a realistic fake accessory with services and characteristics."""
    accessory_id = str(uuid.uuid4()).upper()
    room_id = str(uuid.uuid4()).upper()

    return {
        "id": accessory_id,
        "name": f"Test Accessory {index}",
        "roomId": room_id,
        "roomName": f"Room {index % 20}",
        "category": ["Lightbulb", "Switch", "Thermostat", "Outlet", "Sensor", "Other"][index % 6],
        "isReachable": True,
        "services": [
            {
                "id": str(uuid.uuid4()).upper(),
                "name": f"Test Accessory {index}",
                "serviceType": "lightbulb",
                "characteristics": [
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "power_state",
                        "value": "1" if index % 2 == 0 else "0",
                        "isReadable": True,
                        "isWritable": True
                    },
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "brightness",
                        "value": str(index % 100),
                        "isReadable": True,
                        "isWritable": True
                    },
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "name",
                        "value": f"Test Accessory {index}",
                        "isReadable": True,
                        "isWritable": False
                    }
                ]
            },
            {
                "id": str(uuid.uuid4()).upper(),
                "name": f"Test Accessory {index}",
                "serviceType": "accessory_information",
                "characteristics": [
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "manufacturer",
                        "value": "Test Manufacturer",
                        "isReadable": True,
                        "isWritable": False
                    },
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "model",
                        "value": "Test Model",
                        "isReadable": True,
                        "isWritable": False
                    },
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "serial_number",
                        "value": f"SN{index:06d}",
                        "isReadable": True,
                        "isWritable": False
                    },
                    {
                        "id": str(uuid.uuid4()).upper(),
                        "characteristicType": "firmware_revision",
                        "value": "1.0.0",
                        "isReadable": True,
                        "isWritable": False
                    }
                ]
            }
        ]
    }


def generate_accessories(count: int) -> List[Dict[str, Any]]:
    """Generate a list of fake accessories."""
    return [generate_fake_accessory(i) for i in range(count)]


def generate_stringified_accessories(count: int) -> List[str]:
    """Generate accessories as JSON strings (simulating Mac app behavior)."""
    return [json.dumps(generate_fake_accessory(i)) for i in range(count)]


def test_json_generation(count: int):
    """Test how long it takes to generate JSON strings."""
    print(f"\n{'='*60}")
    print(f"TEST: Generate {count} accessories as JSON strings")
    print('='*60)

    start = time.perf_counter()
    accessories = generate_stringified_accessories(count)
    elapsed = time.perf_counter() - start

    total_size = sum(len(a) for a in accessories)
    print(f"Time: {elapsed*1000:.2f}ms")
    print(f"Total size: {total_size / 1024:.1f} KB")
    print(f"Avg per accessory: {elapsed/count*1000:.3f}ms")

    return accessories


def test_json_parsing(accessories: List[str]):
    """Test how long it takes to parse JSON strings back to dicts."""
    print(f"\n{'='*60}")
    print(f"TEST: Parse {len(accessories)} JSON strings to dicts")
    print('='*60)

    start = time.perf_counter()
    parsed = [json.loads(a) for a in accessories]
    elapsed = time.perf_counter() - start

    print(f"Time: {elapsed*1000:.2f}ms")
    print(f"Avg per accessory: {elapsed/len(accessories)*1000:.3f}ms")

    return parsed


def test_json_serialization(accessories: List[Dict[str, Any]]):
    """Test how long it takes to serialize dicts to JSON (final response)."""
    print(f"\n{'='*60}")
    print(f"TEST: Serialize {len(accessories)} dicts to JSON response")
    print('='*60)

    response = {"data": {"accessories": accessories}}

    start = time.perf_counter()
    result = json.dumps(response)
    elapsed = time.perf_counter() - start

    print(f"Time: {elapsed*1000:.2f}ms")
    print(f"Response size: {len(result) / 1024:.1f} KB")

    return result


def test_graphql_api_overhead():
    """Test graphql-api serialization overhead."""
    print(f"\n{'='*60}")
    print("TEST: graphql-api serialization overhead")
    print('='*60)

    try:
        from graphql_api import field
        from dataclasses import dataclass
        import graphql_api

        @dataclass
        class TestAPI:
            @field
            def accessories(self) -> List[dict]:
                return generate_accessories(600)

        # Build schema
        start = time.perf_counter()
        schema = graphql_api.Schema(TestAPI())
        build_time = time.perf_counter() - start
        print(f"Schema build time: {build_time*1000:.2f}ms")

        # Execute query
        query = "{ accessories }"
        start = time.perf_counter()
        result = schema.execute(query)
        exec_time = time.perf_counter() - start
        print(f"Query execution time: {exec_time*1000:.2f}ms")

        if result.errors:
            print(f"Errors: {result.errors}")
        else:
            # Serialize to JSON
            start = time.perf_counter()
            json_result = json.dumps({"data": result.data})
            serialize_time = time.perf_counter() - start
            print(f"JSON serialization time: {serialize_time*1000:.2f}ms")
            print(f"Response size: {len(json_result) / 1024:.1f} KB")

    except ImportError as e:
        print(f"Could not import graphql_api: {e}")
        print("Run with: cd server && uv run python tests/perf_test.py")


async def test_websocket_simulation():
    """Simulate WebSocket message handling."""
    print(f"\n{'='*60}")
    print("TEST: WebSocket message handling simulation")
    print('='*60)

    # Simulate Mac app sending stringified accessories
    stringified = generate_stringified_accessories(600)
    message = json.dumps({
        "id": "test-123",
        "type": "response",
        "action": "accessories.list",
        "payload": {
            "accessories": stringified
        }
    })

    print(f"WebSocket message size: {len(message) / 1024:.1f} KB")

    # Simulate receiving and parsing
    start = time.perf_counter()
    parsed_message = json.loads(message)
    parse_msg_time = time.perf_counter() - start
    print(f"Parse WebSocket message: {parse_msg_time*1000:.2f}ms")

    # Parse the stringified accessories
    start = time.perf_counter()
    accessories = parsed_message["payload"]["accessories"]
    parsed_accessories = [json.loads(a) if isinstance(a, str) else a for a in accessories]
    parse_acc_time = time.perf_counter() - start
    print(f"Parse accessories from strings: {parse_acc_time*1000:.2f}ms")

    # Serialize response
    start = time.perf_counter()
    response = json.dumps({"data": {"accessories": parsed_accessories}})
    serialize_time = time.perf_counter() - start
    print(f"Serialize final response: {serialize_time*1000:.2f}ms")

    print(f"\nTotal processing time: {(parse_msg_time + parse_acc_time + serialize_time)*1000:.2f}ms")


def test_full_pipeline():
    """Test the full pipeline end to end."""
    print(f"\n{'='*60}")
    print("TEST: Full pipeline (600 accessories)")
    print('='*60)

    total_start = time.perf_counter()

    # Step 1: Mac app generates stringified JSON (simulated)
    start = time.perf_counter()
    stringified = generate_stringified_accessories(600)
    step1 = time.perf_counter() - start
    print(f"1. Generate stringified accessories: {step1*1000:.2f}ms")

    # Step 2: Create WebSocket message
    start = time.perf_counter()
    ws_message = json.dumps({
        "payload": {"accessories": stringified}
    })
    step2 = time.perf_counter() - start
    print(f"2. Create WebSocket message: {step2*1000:.2f}ms ({len(ws_message)/1024:.1f} KB)")

    # Step 3: Parse WebSocket message (server receives)
    start = time.perf_counter()
    parsed = json.loads(ws_message)
    step3 = time.perf_counter() - start
    print(f"3. Parse WebSocket message: {step3*1000:.2f}ms")

    # Step 4: Parse stringified accessories
    start = time.perf_counter()
    accessories = [json.loads(a) for a in parsed["payload"]["accessories"]]
    step4 = time.perf_counter() - start
    print(f"4. Parse accessories from strings: {step4*1000:.2f}ms")

    # Step 5: Serialize final GraphQL response
    start = time.perf_counter()
    response = json.dumps({"data": {"accessories": accessories}})
    step5 = time.perf_counter() - start
    print(f"5. Serialize GraphQL response: {step5*1000:.2f}ms ({len(response)/1024:.1f} KB)")

    total = time.perf_counter() - total_start
    print(f"\nTOTAL: {total*1000:.2f}ms")
    print(f"\nConclusion: If this is fast but real requests are slow,")
    print(f"the bottleneck is in the Mac app or WebSocket transmission.")


def main():
    print("="*60)
    print("HOMEKIT MCP PERFORMANCE TEST")
    print("="*60)
    print(f"Testing with simulated 600 accessories")

    # Run tests
    stringified = test_json_generation(600)
    parsed = test_json_parsing(stringified)
    test_json_serialization(parsed)
    test_graphql_api_overhead()
    asyncio.run(test_websocket_simulation())
    test_full_pipeline()

    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)
    print("""
If all tests complete in < 1 second, the Python server is NOT the bottleneck.

Likely causes of 30+ second delays:
1. Mac app taking too long to enumerate HomeKit accessories
2. Mac app serializing each accessory individually (slow)
3. WebSocket transmission over network
4. Mac app blocking on main thread

Recommended fixes:
1. Profile the Mac app's accessories.list handler
2. Cache accessories on the Mac app side
3. Send accessories as proper JSON objects, not strings
4. Use background threads for HomeKit enumeration
""")


if __name__ == "__main__":
    main()
