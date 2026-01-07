"""
Redis-based WebSocket routing for distributed Cloud Run instances.

When multiple Cloud Run instances are running, WebSocket connections may be on
different instances than GraphQL requests. This module uses Redis to:
1. Track which instance has which device connected
2. Route requests via pub/sub to the correct instance
"""

import asyncio
import json
import logging
import os
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Dict, Optional

import redis.asyncio as redis

from homecast import config

logger = logging.getLogger(__name__)

# Unique ID for this instance
INSTANCE_ID = os.getenv("K_REVISION", str(uuid.uuid4())[:8])


@dataclass
class DeviceLocation:
    """Tracks where a device is connected."""
    device_id: str
    instance_id: str
    user_id: str


class RedisRouter:
    """
    Routes WebSocket messages between Cloud Run instances via Redis.

    Architecture:
    - Each instance subscribes to its own channel: `instance:{instance_id}`
    - Device locations stored in Redis hash: `devices` -> {device_id: instance_id}
    - When a request comes in:
      1. Look up which instance has the device
      2. Publish request to that instance's channel
      3. Wait for response on a reply channel
    """

    def __init__(self):
        self._redis: Optional[redis.Redis] = None
        self._pubsub: Optional[redis.client.PubSub] = None
        self._listener_task: Optional[asyncio.Task] = None
        self._pending_requests: Dict[str, asyncio.Future] = {}
        self._local_handler: Optional[Callable] = None
        self._enabled = bool(config.REDIS_URL)

    @property
    def enabled(self) -> bool:
        return self._enabled

    async def connect(self):
        """Connect to Redis and start listening for messages."""
        if not self._enabled:
            logger.info("Redis not configured - running in local-only mode")
            return

        try:
            self._redis = redis.from_url(config.REDIS_URL, decode_responses=True)
            await self._redis.ping()
            logger.info(f"Connected to Redis, instance ID: {INSTANCE_ID}")

            # Subscribe to our instance channel
            self._pubsub = self._redis.pubsub()
            await self._pubsub.subscribe(f"instance:{INSTANCE_ID}")

            # Start listener
            self._listener_task = asyncio.create_task(self._listen())

        except Exception as e:
            logger.error(f"Failed to connect to Redis: {e}")
            self._enabled = False

    async def disconnect(self):
        """Disconnect from Redis."""
        if self._listener_task:
            self._listener_task.cancel()
            try:
                await self._listener_task
            except asyncio.CancelledError:
                pass

        if self._pubsub:
            await self._pubsub.unsubscribe()
            await self._pubsub.close()

        if self._redis:
            await self._redis.close()

    def set_local_handler(self, handler: Callable):
        """Set the handler for requests to local devices."""
        self._local_handler = handler

    async def register_device(self, device_id: str, user_id: str):
        """Register that a device is connected to this instance."""
        if not self._enabled:
            return

        # Use a separate key per device with TTL (expires if not refreshed)
        key = f"device:{device_id}"
        await self._redis.set(key, json.dumps({
            "instance_id": INSTANCE_ID,
            "user_id": str(user_id)
        }), ex=60)  # 60 second TTL - must be refreshed by heartbeat
        logger.info(f"Registered device {device_id} on instance {INSTANCE_ID}")

    async def unregister_device(self, device_id: str):
        """Unregister a device when it disconnects."""
        if not self._enabled:
            return

        key = f"device:{device_id}"
        await self._redis.delete(key)
        logger.info(f"Unregistered device {device_id}")

    async def refresh_device(self, device_id: str):
        """Refresh device TTL - call this on heartbeat."""
        if not self._enabled:
            return

        key = f"device:{device_id}"
        await self._redis.expire(key, 60)  # Refresh to 60 seconds

    async def get_device_location(self, device_id: str) -> Optional[DeviceLocation]:
        """Get which instance a device is connected to."""
        if not self._enabled:
            return None

        key = f"device:{device_id}"
        data = await self._redis.get(key)
        if not data:
            return None

        info = json.loads(data)
        return DeviceLocation(
            device_id=device_id,
            instance_id=info["instance_id"],
            user_id=info["user_id"]
        )

    async def send_request(
        self,
        device_id: str,
        action: str,
        payload: Dict[str, Any],
        timeout: float = 30.0
    ) -> Dict[str, Any]:
        """
        Send a request to a device, routing via Redis if needed.

        Returns the response payload.
        Raises ValueError if device not found or error.
        Raises TimeoutError if no response in time.
        """
        # Check if Redis is enabled
        if not self._enabled:
            # Local-only mode - use local handler directly
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Look up device location
        location = await self.get_device_location(device_id)
        if not location:
            raise ValueError(f"Device {device_id} not connected")

        # If device is on this instance, handle locally
        if location.instance_id == INSTANCE_ID:
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Route to remote instance via Redis
        request_id = str(uuid.uuid4())
        reply_channel = f"reply:{request_id}"

        # Create future for response
        future: asyncio.Future = asyncio.Future()
        self._pending_requests[request_id] = future

        try:
            # Subscribe to reply channel
            await self._pubsub.subscribe(reply_channel)

            # Publish request to target instance
            await self._redis.publish(f"instance:{location.instance_id}", json.dumps({
                "type": "request",
                "request_id": request_id,
                "reply_channel": reply_channel,
                "device_id": device_id,
                "action": action,
                "payload": payload
            }))

            logger.info(f"Routed request {request_id[:8]} to instance {location.instance_id}")

            # Wait for response
            result = await asyncio.wait_for(future, timeout=timeout)

            if "error" in result:
                raise ValueError(result["error"].get("message", "Unknown error"))

            return result.get("payload", {})

        finally:
            # Cleanup
            self._pending_requests.pop(request_id, None)
            await self._pubsub.unsubscribe(reply_channel)

    async def _listen(self):
        """Listen for incoming messages on our instance channel."""
        try:
            async for message in self._pubsub.listen():
                if message["type"] != "message":
                    continue

                channel = message["channel"]

                # Handle reply messages
                if channel.startswith("reply:"):
                    request_id = channel.split(":", 1)[1]
                    if request_id in self._pending_requests:
                        data = json.loads(message["data"])
                        self._pending_requests[request_id].set_result(data)
                    continue

                # Handle request messages to our instance
                if channel == f"instance:{INSTANCE_ID}":
                    asyncio.create_task(self._handle_remote_request(message["data"]))

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Redis listener error: {e}")

    async def _handle_remote_request(self, data: str):
        """Handle a request routed from another instance."""
        try:
            msg = json.loads(data)
            request_id = msg["request_id"]
            reply_channel = msg["reply_channel"]
            device_id = msg["device_id"]
            action = msg["action"]
            payload = msg.get("payload", {})

            logger.info(f"Handling remote request {request_id[:8]} for device {device_id}")

            # Execute locally
            try:
                if self._local_handler:
                    result = await self._local_handler(device_id, action, payload, 30.0)
                    response = {"payload": result}
                else:
                    response = {"error": {"code": "NO_HANDLER", "message": "No local handler"}}
            except ValueError as e:
                response = {"error": {"code": "ERROR", "message": str(e)}}
            except TimeoutError:
                response = {"error": {"code": "TIMEOUT", "message": "Request timed out"}}
            except Exception as e:
                response = {"error": {"code": "INTERNAL_ERROR", "message": str(e)}}

            # Send response back
            await self._redis.publish(reply_channel, json.dumps(response))

        except Exception as e:
            logger.error(f"Error handling remote request: {e}")


# Global router instance
router = RedisRouter()
