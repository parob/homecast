"""
WebSocket handler for HomeKit Mac app connections.

Implements the protocol defined in PROTOCOL.md.
"""

import asyncio
import json
import logging
import queue
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Optional, Any, List

from starlette.websockets import WebSocket, WebSocketDisconnect

from homecast.auth import verify_token, extract_token_from_header
from homecast.models.db.database import get_session
from homecast.models.db.models import SessionType
from homecast.models.db.repositories import SessionRepository, HomeRepository
from homecast.websocket.pubsub_router import router as pubsub_router
from homecast.websocket.web_clients import web_client_manager
from homecast import config

logger = logging.getLogger(__name__)


# --- Error Codes (from PROTOCOL.md) ---

class ErrorCode:
    INVALID_REQUEST = "INVALID_REQUEST"
    UNKNOWN_ACTION = "UNKNOWN_ACTION"
    HOME_NOT_FOUND = "HOME_NOT_FOUND"
    ROOM_NOT_FOUND = "ROOM_NOT_FOUND"
    ACCESSORY_NOT_FOUND = "ACCESSORY_NOT_FOUND"
    SCENE_NOT_FOUND = "SCENE_NOT_FOUND"
    CHARACTERISTIC_NOT_FOUND = "CHARACTERISTIC_NOT_FOUND"
    CHARACTERISTIC_NOT_WRITABLE = "CHARACTERISTIC_NOT_WRITABLE"
    ACCESSORY_UNREACHABLE = "ACCESSORY_UNREACHABLE"
    INVALID_VALUE = "INVALID_VALUE"
    HOMEKIT_ERROR = "HOMEKIT_ERROR"
    INTERNAL_ERROR = "INTERNAL_ERROR"


# --- Data Classes ---

@dataclass
class ConnectedDevice:
    """Represents a connected HomeKit Mac app."""
    websocket: WebSocket
    user_id: uuid.UUID
    device_id: str
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class PendingRequest:
    """A request waiting for a response from a device."""
    id: str
    device_id: str
    action: str
    # Use thread-safe queue - asyncio primitives don't work across different async contexts
    queue: "queue.Queue[Dict[str, Any]]" = field(default_factory=lambda: queue.Queue(maxsize=1))
    response_payload: Optional[Dict[str, Any]] = None
    error: Optional[Dict[str, str]] = None


# --- Connection Manager ---

class ConnectionManager:
    """Manages WebSocket connections from HomeKit Mac apps."""

    def __init__(self):
        # device_id -> ConnectedDevice
        self.connections: Dict[str, ConnectedDevice] = {}
        # request_id -> PendingRequest
        self.pending_requests: Dict[str, PendingRequest] = {}
        # Lock for thread-safe operations (created per event loop)
        self._lock: Optional[asyncio.Lock] = None
        self._lock_loop: Optional[asyncio.AbstractEventLoop] = None

    @property
    def lock(self) -> asyncio.Lock:
        """Get the lock, creating it in the current event loop if needed."""
        current_loop = asyncio.get_running_loop()
        if self._lock is None or self._lock_loop is not current_loop:
            self._lock = asyncio.Lock()
            self._lock_loop = current_loop
        return self._lock

    async def connect(
        self,
        websocket: WebSocket,
        token: str,
        device_id: str,
        device_name: Optional[str] = None
    ) -> Optional[ConnectedDevice]:
        """
        Accept and register a new WebSocket connection.

        Args:
            websocket: The WebSocket connection
            token: JWT token for authentication
            device_id: Unique device identifier
            device_name: Optional device name (e.g., Mac's computer name)

        Returns:
            ConnectedDevice if successful, None if auth fails
        """
        # Verify token
        auth = verify_token(token)
        if not auth:
            logger.warning(f"Invalid token for device {device_id}")
            # Must accept before closing with custom code
            await websocket.accept()
            await websocket.close(code=4001, reason="Invalid token")
            return None

        await websocket.accept()

        async with self.lock:
            # Close existing connection for this device if any
            if device_id in self.connections:
                old_conn = self.connections[device_id]
                try:
                    await old_conn.websocket.close(code=4002, reason="Replaced by new connection")
                except Exception:
                    pass

            # Register new connection
            device = ConnectedDevice(
                websocket=websocket,
                user_id=auth.user_id,
                device_id=device_id
            )
            self.connections[device_id] = device

        # Create/update session in database
        name = device_name or f"HomeKit Device ({device_id[:8]})"
        instance_id = pubsub_router.instance_id if pubsub_router.enabled else "local"

        with get_session() as db:
            SessionRepository.create_session(
                db,
                user_id=auth.user_id,
                instance_id=instance_id,
                session_type=SessionType.DEVICE,
                device_id=device_id,
                name=name
            )

        logger.info(f"Device connected: {device_id} (user: {auth.user_id}, instance: {instance_id})")

        # Log device connection to system logs
        try:
            from homecast.utils.system_logger import SystemLogger
            SystemLogger.info(
                "websocket", "Device connected",
                user_id=auth.user_id, device_id=device_id,
                metadata={"instance_id": instance_id, "device_name": name}
            )
        except Exception:
            pass  # Don't let logging errors affect connection

        # Proactively fetch and cache homes for MCP routing
        asyncio.create_task(self._fetch_and_cache_homes(device_id))

        return device

    async def _fetch_and_cache_homes(self, device_id: str):
        """Fetch homes from device and cache them for MCP routing."""
        try:
            # Small delay to ensure device is ready
            await asyncio.sleep(0.5)

            if device_id not in self.connections:
                return

            result = await self.send_request(device_id, "homes.list", {}, timeout=10.0)
            # The response will be handled by handle_message which calls _cache_homes
            logger.info(f"Proactively fetched homes for device {device_id}")
        except Exception as e:
            logger.warning(f"Failed to proactively fetch homes for {device_id}: {e}")

    async def disconnect(self, device_id: str):
        """Handle device disconnection."""
        # Get user_id before removing connection (for logging)
        user_id = None
        async with self.lock:
            if device_id in self.connections:
                user_id = self.connections[device_id].user_id
                del self.connections[device_id]

        # Delete session from database
        with get_session() as db:
            SessionRepository.delete_by_device_id(db, device_id)

        logger.info(f"Device disconnected: {device_id}")

        # Log device disconnection to system logs
        try:
            from homecast.utils.system_logger import SystemLogger
            SystemLogger.info(
                "websocket", "Device disconnected",
                user_id=user_id, device_id=device_id
            )
        except Exception:
            pass  # Don't let logging errors affect disconnection

    async def send_request(
        self,
        device_id: str,
        action: str,
        payload: Dict[str, Any],
        timeout: float = 30.0,
        routing_metadata: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        """
        Send a request to a device and wait for response.

        Follows PROTOCOL.md message format.

        Args:
            device_id: Target device ID
            action: Action name (e.g., "homes.list", "characteristic.set")
            payload: Action payload
            timeout: Timeout in seconds
            routing_metadata: Optional routing info for debugging (from Pub/Sub router)

        Returns:
            Response payload from the device

        Raises:
            ValueError: If device not connected or error response
            TimeoutError: If response not received in time
        """
        import time
        t0 = time.time()

        if device_id not in self.connections:
            raise ValueError(f"Device {device_id} not connected")

        request_id = str(uuid.uuid4())
        pending = PendingRequest(id=request_id, device_id=device_id, action=action)

        t1 = time.time()
        async with self.lock:
            self.pending_requests[request_id] = pending
        t2 = time.time()
        logger.info(f"[{request_id[:8]}] Lock acquired in {(t2-t1)*1000:.0f}ms")

        try:
            # Send request to device (PROTOCOL.md format)
            conn = self.connections[device_id]
            instance_id = pubsub_router.instance_id if pubsub_router.enabled else "local"

            # Use provided routing metadata (from Pub/Sub) or create default (direct connection)
            if routing_metadata:
                ws_routing = routing_metadata
            else:
                ws_routing = {
                    "sourceInstance": instance_id,  # Web client connected here
                    "targetInstance": instance_id,  # Mac app connected here (same for direct)
                    "routedViaPubsub": False,
                    "directConnection": True
                }

            ws_message = {
                "id": request_id,
                "type": "request",
                "action": action,
                "payload": payload,
                "_routing": ws_routing
            }
            logger.info(f"[{request_id[:8]}] WS SEND to {device_id}: {ws_message}")
            t3 = time.time()
            await conn.websocket.send_json(ws_message)
            t4 = time.time()
            logger.info(f"[{request_id[:8]}] WebSocket send took {(t4-t3)*1000:.0f}ms")

            # Wait for response via thread-safe queue (asyncio primitives don't work across contexts)
            try:
                logger.info(f"[{request_id[:8]}] Waiting for response via thread-safe queue...")

                # Use thread pool to wait on blocking queue.get()
                loop = asyncio.get_event_loop()
                result = await loop.run_in_executor(
                    None,
                    lambda: pending.queue.get(timeout=timeout)
                )

                t5 = time.time()
                logger.info(f"[{request_id[:8]}] Response received in {(t5-t4)*1000:.0f}ms (total: {(t5-t0)*1000:.0f}ms)")
            except queue.Empty:
                raise TimeoutError(f"Device {device_id} did not respond in time")

            if result.get("error"):
                err = result["error"]
                raise ValueError(f"{err.get('code', 'ERROR')}: {err.get('message', 'Unknown error')}")

            return result.get("payload", {})

        finally:
            async with self.lock:
                self.pending_requests.pop(request_id, None)

    async def handle_message(self, device_id: str, message: Dict[str, Any]):
        """
        Handle an incoming message from a device.

        Expects PROTOCOL.md format with id, type, action, payload, error.
        """
        import time
        recv_time = time.time()

        msg_id = message.get("id")
        msg_type = message.get("type")
        action = message.get("action")

        logger.info(f"handle_message: type={msg_type}, action={action}, id={msg_id}")

        if msg_type == "response":
            # Response to a request we sent
            if msg_id and msg_id in self.pending_requests:
                pending = self.pending_requests[msg_id]

                # Log full response (truncate payload if huge)
                payload_preview = message.get("payload", {})
                payload_str = str(payload_preview)
                if len(payload_str) > 500:
                    payload_str = payload_str[:500] + "...(truncated)"
                error_info = message.get("error")
                logger.info(f"[{msg_id[:8]}] WS RECV: action={action}, error={error_info}, payload={payload_str}")

                # Put result in queue (includes error or payload)
                result = {}
                if "error" in message:
                    result["error"] = message["error"]
                else:
                    result["payload"] = message.get("payload", {})

                    # Cache homes for MCP routing when we receive a homes.list response
                    if action == "homes.list":
                        await self._cache_homes(device_id, result["payload"])

                try:
                    pending.queue.put_nowait(result)
                    logger.info(f"Result queued for {msg_id}")
                except queue.Full:
                    logger.error(f"Queue full for {msg_id} - duplicate response?")
            else:
                logger.warning(f"No pending request found for id={msg_id}, pending_ids={list(self.pending_requests.keys())}")

        elif msg_type == "status":
            # Device status update (extension to protocol) - just log it
            payload = message.get("payload", {})
            logger.debug(f"Device {device_id} status: {payload}")

        elif msg_type == "pong":
            # Heartbeat response - update last seen time and instance_id in database
            # Updating instance_id on every heartbeat ensures session always reflects
            # the current location of the device, preventing stale routing
            with get_session() as db:
                SessionRepository.update_heartbeat_by_device(db, device_id, instance_id=pubsub_router.instance_id)

        elif msg_type == "event":
            # Event from Mac app (e.g., characteristic update)
            await self._handle_event(device_id, action, message.get("payload", {}))

        else:
            logger.warning(f"Unknown message type from {device_id}: {msg_type}")

    async def _handle_event(self, device_id: str, action: Optional[str], payload: Dict[str, Any]):
        """Handle an event message from a Mac app (e.g., characteristic update)."""
        if action == "characteristic.updated":
            accessory_id = payload.get("accessoryId")
            characteristic_type = payload.get("characteristicType")
            value = payload.get("value")

            if not all([accessory_id, characteristic_type]):
                logger.warning(f"Invalid characteristic.updated event from {device_id}")
                return

            # Get user_id for this device
            if device_id in self.connections:
                user_id = self.connections[device_id].user_id

                # Broadcast to local web clients for this user
                await web_client_manager.broadcast_characteristic_update(
                    user_id=user_id,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type,
                    value=value
                )

                # Broadcast to web clients on other instances via Pub/Sub
                await pubsub_router.broadcast_characteristic_update(
                    user_id=user_id,
                    accessory_id=accessory_id,
                    characteristic_type=characteristic_type,
                    value=value
                )

                # Broadcast to shared view subscribers (for shared collections)
                await web_client_manager.broadcast_to_share_subscribers(
                    owner_id=user_id,
                    accessory_id=accessory_id,
                    message={
                        "type": "characteristic_update",
                        "accessoryId": accessory_id,
                        "characteristicType": characteristic_type,
                        "value": value
                    }
                )

                logger.info(f"Broadcast characteristic update to user {user_id}: {accessory_id}/{characteristic_type}")

        elif action == "accessory.reachability":
            accessory_id = payload.get("accessoryId")
            is_reachable = payload.get("isReachable")

            if accessory_id is None or is_reachable is None:
                logger.warning(f"Invalid accessory.reachability event from {device_id}")
                return

            # Get user_id for this device
            if device_id in self.connections:
                user_id = self.connections[device_id].user_id

                # Broadcast to local web clients for this user
                await web_client_manager.broadcast_reachability_update(
                    user_id=user_id,
                    accessory_id=accessory_id,
                    is_reachable=is_reachable
                )

                # Broadcast to web clients on other instances via Pub/Sub
                await pubsub_router.broadcast_reachability_update(
                    user_id=user_id,
                    accessory_id=accessory_id,
                    is_reachable=is_reachable
                )

                # Broadcast to shared view subscribers (for shared collections)
                await web_client_manager.broadcast_to_share_subscribers(
                    owner_id=user_id,
                    accessory_id=accessory_id,
                    message={
                        "type": "reachability_update",
                        "accessoryId": accessory_id,
                        "isReachable": is_reachable
                    }
                )

                logger.info(f"Broadcast reachability update to user {user_id}: {accessory_id} -> {'reachable' if is_reachable else 'unreachable'}")

        else:
            logger.warning(f"Unknown event action from {device_id}: {action}")

    async def _cache_homes(self, device_id: str, payload: Dict[str, Any]):
        """
        Cache homes from a homes.list response for MCP routing.

        When a device reports its homes, we store them in the database so
        MCP requests can be routed to the correct user/device based on home_id.
        """
        homes = payload.get("homes", [])
        if not homes:
            return

        # Get user_id for this device
        if device_id not in self.connections:
            logger.warning(f"Cannot cache homes: device {device_id} not in connections")
            return

        user_id = self.connections[device_id].user_id

        try:
            with get_session() as db:
                HomeRepository.upsert_homes(db, user_id, homes)
            logger.info(f"Cached {len(homes)} homes for user {user_id}")
        except Exception as e:
            logger.error(f"Failed to cache homes for user {user_id}: {e}", exc_info=True)

    def is_connected(self, device_id: str) -> bool:
        """Check if a device is currently connected."""
        return device_id in self.connections

    def get_user_devices(self, user_id: uuid.UUID) -> List[str]:
        """Get all connected device IDs for a user."""
        return [
            device_id
            for device_id, conn in self.connections.items()
            if conn.user_id == user_id
        ]

    async def get_user_device(self, user_id: uuid.UUID) -> Optional[str]:
        """Get first connected device for a user."""
        devices = self.get_user_devices(user_id)
        return devices[0] if devices else None


# Global connection manager instance
connection_manager = ConnectionManager()


async def websocket_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for HomeKit Mac app connections.

    Authentication via:
    - Authorization header: "Bearer <token>"
    - Query param fallback: ?token=<token>

    Device ID via:
    - Query param: ?device_id=<id>
    """
    import time

    # Log incoming connection for debugging
    logger.info(f"WebSocket connection attempt - path: {websocket.url.path}, query: {websocket.query_params}")

    # Get auth token from header or query param
    auth_header = websocket.headers.get("authorization")
    token = extract_token_from_header(auth_header)

    if not token:
        # Fallback to query param
        token = websocket.query_params.get("token")

    device_id = websocket.query_params.get("device_id")
    device_name = websocket.query_params.get("device_name")

    # Must accept WebSocket before we can close it with a custom code
    if not token or not device_id:
        logger.warning(f"WebSocket rejected: missing token={bool(token)}, device_id={bool(device_id)}")
        # Accept first, then close with error code
        await websocket.accept()
        await websocket.close(code=4000, reason="Missing token or device_id")
        return

    # Connect
    device = await connection_manager.connect(websocket, token, device_id, device_name)
    if not device:
        return

    try:
        # Message loop
        while True:
            t_recv_start = time.time()
            data = await websocket.receive_text()
            t_recv_end = time.time()

            data_size = len(data)
            logger.info(f"WS received {data_size} bytes in {(t_recv_end-t_recv_start)*1000:.0f}ms")

            try:
                t_parse_start = time.time()
                # Offload large JSON parsing to thread pool to avoid blocking event loop
                message = await asyncio.get_event_loop().run_in_executor(None, json.loads, data)
                t_parse_end = time.time()
                logger.info(f"JSON parse took {(t_parse_end-t_parse_start)*1000:.0f}ms")

                t_handle_start = time.time()
                await connection_manager.handle_message(device_id, message)
                t_handle_end = time.time()
                logger.info(f"handle_message took {(t_handle_end-t_handle_start)*1000:.0f}ms")

            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON from {device_id}: {data[:100]}")

    except WebSocketDisconnect:
        await connection_manager.disconnect(device_id)
    except Exception as e:
        logger.error(f"WebSocket error for {device_id}: {e}", exc_info=True)
        await connection_manager.disconnect(device_id)


async def ping_clients():
    """Periodically ping connected clients and confirm listener status (30s as per PROTOCOL.md)."""
    while True:
        await asyncio.sleep(30)

        disconnected = []
        for device_id, conn in list(connection_manager.connections.items()):
            try:
                # Check if this user has web clients listening (queries database)
                has_listeners = web_client_manager.has_listeners(conn.user_id)

                # Send ping with listener status so Mac app can reset timeout
                await conn.websocket.send_json({
                    "type": "ping",
                    "payload": {"webClientsListening": has_listeners}
                })
            except Exception:
                disconnected.append(device_id)

        for device_id in disconnected:
            await connection_manager.disconnect(device_id)


async def init_pubsub_router():
    """Initialize Pub/Sub router for cross-instance WebSocket routing."""
    # Set the local handler for requests to devices on this instance
    pubsub_router.set_local_handler(connection_manager.send_request)

    # Set the local device checker (fast path to avoid DB lookup)
    pubsub_router.set_local_device_checker(connection_manager.is_connected)

    # Connect to Pub/Sub
    await pubsub_router.connect()

    logger.info(f"Pub/Sub router initialized (enabled={pubsub_router.enabled})")


async def shutdown_pubsub_router():
    """Shutdown Pub/Sub router on app shutdown."""
    await pubsub_router.disconnect()
    logger.info("Pub/Sub router disconnected")


async def get_user_device_id(user_id: uuid.UUID) -> Optional[str]:
    """
    Get first connected device for a user.

    Checks local connections first (fast), then falls back to database lookup
    which may return a device on another instance.
    """
    # 1. Check local connections first (fast)
    local_device = await connection_manager.get_user_device(user_id)
    if local_device:
        return local_device

    # 2. Check database for active device sessions (may be on another instance)
    with get_session() as db:
        session = SessionRepository.get_user_device_session(db, user_id)
        if session and session.device_id:
            return session.device_id

    return None


async def route_request(
    device_id: str,
    action: str,
    payload: Dict[str, Any],
    timeout: float = 30.0
) -> Dict[str, Any]:
    """
    Route a request to a device, using Pub/Sub if needed for cross-instance routing.

    This is the main entry point for sending requests to devices - it handles
    both local and remote devices transparently.
    """
    logger.info(f"route_request: device={device_id}, action={action}, payload={payload}")
    if pubsub_router.enabled:
        logger.info(f"route_request: using Pub/Sub router")
        result = await pubsub_router.send_request(device_id, action, payload, timeout)
        logger.info(f"route_request: response={result}")
        return result
    else:
        # Local-only mode
        logger.info(f"route_request: using direct local connection")
        result = await connection_manager.send_request(device_id, action, payload, timeout)
        logger.info(f"route_request: response={result}")
        return result
