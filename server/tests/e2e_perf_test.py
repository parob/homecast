#!/usr/bin/env python3
"""
End-to-end performance test that simulates a real Mac app connection.

This test:
1. Starts the server
2. Connects via WebSocket as a fake Mac app
3. Sends accessory data when requested
4. Measures the full round-trip time via GraphQL
"""

import asyncio
import json
import time
import uuid
import aiohttp
import sys

# Configuration
SERVER_URL = "http://localhost:8090"
WS_URL = "ws://localhost:8090/ws"
NUM_ACCESSORIES = 600

# Test user credentials
TEST_EMAIL = "perf-test@example.com"
TEST_PASSWORD = "testpassword123"


def generate_accessory(i: int) -> dict:
    """Generate a realistic accessory."""
    return {
        "id": str(uuid.uuid4()).upper(),
        "name": f"Test Accessory {i}",
        "roomId": str(uuid.uuid4()).upper(),
        "roomName": f"Room {i % 20}",
        "category": ["Lightbulb", "Switch", "Thermostat", "Outlet"][i % 4],
        "isReachable": True,
        "services": [
            {
                "id": str(uuid.uuid4()).upper(),
                "name": f"Test {i}",
                "serviceType": "lightbulb",
                "characteristics": [
                    {"id": str(uuid.uuid4()).upper(), "characteristicType": "power_state", "value": "1", "isReadable": True, "isWritable": True},
                    {"id": str(uuid.uuid4()).upper(), "characteristicType": "brightness", "value": str(i % 100), "isReadable": True, "isWritable": True},
                ]
            },
            {
                "id": str(uuid.uuid4()).upper(),
                "name": f"Test {i}",
                "serviceType": "accessory_information",
                "characteristics": [
                    {"id": str(uuid.uuid4()).upper(), "characteristicType": "manufacturer", "value": "Test Corp", "isReadable": True, "isWritable": False},
                    {"id": str(uuid.uuid4()).upper(), "characteristicType": "model", "value": "Model X", "isReadable": True, "isWritable": False},
                ]
            }
        ]
    }


async def signup_or_login(session: aiohttp.ClientSession) -> str:
    """Get an auth token."""
    # Try signup first
    query = """
    mutation Signup($email: String!, $password: String!) {
        signup(email: $email, password: $password) {
            success
            token
            error
        }
    }
    """
    async with session.post(
        f"{SERVER_URL}/",
        json={"query": query, "variables": {"email": TEST_EMAIL, "password": TEST_PASSWORD}}
    ) as resp:
        data = await resp.json()
        result = data.get("data", {}).get("signup", {})
        if result.get("success"):
            return result["token"]

    # Try login
    query = """
    mutation Login($email: String!, $password: String!) {
        login(email: $email, password: $password) {
            success
            token
            error
        }
    }
    """
    async with session.post(
        f"{SERVER_URL}/",
        json={"query": query, "variables": {"email": TEST_EMAIL, "password": TEST_PASSWORD}}
    ) as resp:
        data = await resp.json()
        result = data.get("data", {}).get("login", {})
        if result.get("success"):
            return result["token"]
        raise Exception(f"Auth failed: {result.get('error')}")


async def fake_mac_app(token: str, device_id: str, accessories: list):
    """Simulate a Mac app connected via WebSocket."""
    url = f"{WS_URL}?token={token}&device_id={device_id}"

    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(url) as ws:
            print(f"[Mac App] Connected to WebSocket")

            # Listen for requests and respond
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    data = json.loads(msg.data)

                    if data.get("type") == "ping":
                        await ws.send_json({"type": "pong"})
                        continue

                    if data.get("type") == "request":
                        request_id = data.get("id")
                        action = data.get("action")

                        print(f"[Mac App] Received request: {action}")

                        if action == "accessories.list":
                            # Simulate Mac app response time
                            # In real app, this is where HomeKit enumeration happens
                            start = time.perf_counter()

                            # Convert to strings (simulating what Mac app does)
                            stringified = [json.dumps(a) for a in accessories]

                            response = {
                                "id": request_id,
                                "type": "response",
                                "action": action,
                                "payload": {"accessories": stringified}
                            }

                            await ws.send_json(response)
                            elapsed = (time.perf_counter() - start) * 1000
                            print(f"[Mac App] Sent {len(accessories)} accessories in {elapsed:.0f}ms")
                            return  # Exit after first request

                elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    break


async def graphql_request(session: aiohttp.ClientSession, token: str) -> float:
    """Make a GraphQL request and return the time taken."""
    query = """
    query GetAccessories {
        accessories {
            id
            name
            category
            isReachable
            roomName
        }
    }
    """

    # Note: We're requesting specific fields but the server returns dict
    # which means all fields are included anyway

    headers = {"Authorization": f"Bearer {token}"}

    start = time.perf_counter()
    async with session.post(
        f"{SERVER_URL}/",
        json={"query": "{ accessories }", "operationName": "GetAccessories"},
        headers=headers
    ) as resp:
        data = await resp.json()
        elapsed = (time.perf_counter() - start) * 1000

        accessories = data.get("data", {}).get("accessories", [])
        print(f"[GraphQL] Received {len(accessories)} accessories in {elapsed:.0f}ms")

        if accessories:
            # Check if they're strings or objects
            first = accessories[0]
            if isinstance(first, str):
                print(f"[GraphQL] WARNING: Accessories are still strings!")
            else:
                print(f"[GraphQL] Accessories are properly parsed objects")

        return elapsed


async def run_test():
    print("=" * 60)
    print(f"E2E PERFORMANCE TEST - {NUM_ACCESSORIES} accessories")
    print("=" * 60)

    # Pre-generate accessories
    print(f"\nGenerating {NUM_ACCESSORIES} test accessories...")
    start = time.perf_counter()
    accessories = [generate_accessory(i) for i in range(NUM_ACCESSORIES)]
    print(f"Generated in {(time.perf_counter()-start)*1000:.0f}ms")

    async with aiohttp.ClientSession() as session:
        # Get auth token
        print("\nAuthenticating...")
        try:
            token = await signup_or_login(session)
            print(f"Got token: {token[:20]}...")
        except Exception as e:
            print(f"Auth failed: {e}")
            return

        device_id = f"perf-test-{uuid.uuid4().hex[:8]}"

        # Start fake Mac app in background
        print(f"\nStarting fake Mac app (device: {device_id})...")
        mac_app_task = asyncio.create_task(
            fake_mac_app(token, device_id, accessories)
        )

        # Wait for WebSocket connection
        await asyncio.sleep(0.5)

        # Make GraphQL request
        print("\nMaking GraphQL request...")
        elapsed = await graphql_request(session, token)

        # Wait for Mac app to finish
        try:
            await asyncio.wait_for(mac_app_task, timeout=5)
        except asyncio.TimeoutError:
            pass

        print("\n" + "=" * 60)
        print("RESULTS")
        print("=" * 60)
        print(f"Total round-trip time: {elapsed:.0f}ms")
        print(f"")
        if elapsed < 1000:
            print("PASS: Response time is acceptable")
        elif elapsed < 5000:
            print("WARN: Response time is slow but acceptable")
        else:
            print("FAIL: Response time is too slow")
            print("")
            print("Likely causes:")
            print("1. Mac app HomeKit enumeration is slow")
            print("2. WebSocket transmission delay")
            print("3. Server processing (unlikely based on unit tests)")


if __name__ == "__main__":
    asyncio.run(run_test())
