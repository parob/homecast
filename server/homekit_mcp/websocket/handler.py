"""
WebSocket handler for HomeKit Mac app connections.

Implements the protocol defined in PROTOCOL.md.
"""

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Optional, Any, List

from starlette.websockets import WebSocket, WebSocketDisconnect

from homekit_mcp.auth import verify_token, extract_token_from_header
from homekit_mcp.models.db.database import get_session
from homekit_mcp.models.db.repositories import DeviceRepository

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
    # Use Queue instead of Event - more reliable across async contexts
    queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=1))
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
        # Lock for thread-safe operations
        self._lock = asyncio.Lock()

    async def connect(
        self,
        websocket: WebSocket,
        token: str,
        device_id: str
    ) -> Optional[ConnectedDevice]:
        """
        Accept and register a new WebSocket connection.

        Args:
            websocket: The WebSocket connection
            token: JWT token for authentication
            device_id: Unique device identifier

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

        async with self._lock:
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

        # Auto-register device if not exists, then set online
        with get_session() as session:
            existing = DeviceRepository.find_by_device_id(session, device_id)
            if not existing:
                # Auto-register the device
                DeviceRepository.register_device(
                    session=session,
                    user_id=auth.user_id,
                    device_id=device_id,
                    name=f"HomeKit Device ({device_id[:8]})"
                )
                logger.info(f"Auto-registered new device: {device_id}")

            DeviceRepository.set_online(session, device_id)

        logger.info(f"Device connected: {device_id} (user: {auth.user_id})")

        return device

    async def disconnect(self, device_id: str):
        """Handle device disconnection."""
        async with self._lock:
            if device_id in self.connections:
                del self.connections[device_id]

        # Update device status in database
        with get_session() as session:
            DeviceRepository.set_offline(session, device_id)

        logger.info(f"Device disconnected: {device_id}")

    async def send_request(
        self,
        device_id: str,
        action: str,
        payload: Dict[str, Any],
        timeout: float = 30.0
    ) -> Dict[str, Any]:
        """
        Send a request to a device and wait for response.

        Follows PROTOCOL.md message format.

        Args:
            device_id: Target device ID
            action: Action name (e.g., "homes.list", "characteristic.set")
            payload: Action payload
            timeout: Timeout in seconds

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
        async with self._lock:
            self.pending_requests[request_id] = pending
        t2 = time.time()
        logger.info(f"[{request_id[:8]}] Lock acquired in {(t2-t1)*1000:.0f}ms")

        try:
            # Send request to device (PROTOCOL.md format)
            conn = self.connections[device_id]
            t3 = time.time()
            await conn.websocket.send_json({
                "id": request_id,
                "type": "request",
                "action": action,
                "payload": payload
            })
            t4 = time.time()
            logger.info(f"[{request_id[:8]}] WebSocket send took {(t4-t3)*1000:.0f}ms")

            # Wait for response via queue (more reliable than Event across async contexts)
            try:
                logger.info(f"[{request_id[:8]}] Waiting for response via queue...")
                result = await asyncio.wait_for(pending.queue.get(), timeout=timeout)
                t5 = time.time()
                logger.info(f"[{request_id[:8]}] Response received in {(t5-t4)*1000:.0f}ms (total: {(t5-t0)*1000:.0f}ms)")
            except asyncio.TimeoutError:
                raise TimeoutError(f"Device {device_id} did not respond in time")

            if result.get("error"):
                err = result["error"]
                raise ValueError(f"{err.get('code', 'ERROR')}: {err.get('message', 'Unknown error')}")

            return result.get("payload", {})

        finally:
            async with self._lock:
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
                logger.info(f"Found pending request {msg_id}, putting result in queue")

                # Put result in queue (includes error or payload)
                result = {}
                if "error" in message:
                    result["error"] = message["error"]
                else:
                    result["payload"] = message.get("payload", {})

                try:
                    pending.queue.put_nowait(result)
                    logger.info(f"Result queued for {msg_id}")
                except asyncio.QueueFull:
                    logger.error(f"Queue full for {msg_id} - duplicate response?")
            else:
                logger.warning(f"No pending request found for id={msg_id}, pending_ids={list(self.pending_requests.keys())}")

        elif msg_type == "status":
            # Device status update (extension to protocol)
            payload = message.get("payload", {})
            home_count = payload.get("homeCount", 0)
            accessory_count = payload.get("accessoryCount", 0)

            with get_session() as session:
                DeviceRepository.set_online(
                    session, device_id,
                    home_count=home_count,
                    accessory_count=accessory_count
                )

        elif msg_type == "pong":
            # Heartbeat response - update last seen time
            with get_session() as session:
                DeviceRepository.update_heartbeat(session, device_id)

        else:
            logger.warning(f"Unknown message type from {device_id}: {msg_type}")

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

    # Must accept WebSocket before we can close it with a custom code
    if not token or not device_id:
        logger.warning(f"WebSocket rejected: missing token={bool(token)}, device_id={bool(device_id)}")
        # Accept first, then close with error code
        await websocket.accept()
        await websocket.close(code=4000, reason="Missing token or device_id")
        return

    # Connect
    device = await connection_manager.connect(websocket, token, device_id)
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
    """Periodically ping connected clients to keep connections alive (30s as per PROTOCOL.md)."""
    while True:
        await asyncio.sleep(30)

        disconnected = []
        for device_id, conn in list(connection_manager.connections.items()):
            try:
                await conn.websocket.send_json({"type": "ping"})
            except Exception:
                disconnected.append(device_id)

        for device_id in disconnected:
            await connection_manager.disconnect(device_id)
