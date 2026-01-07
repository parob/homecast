"""
WebSocket handler for HomeKit Mac app connections.

Manages persistent connections from Mac apps and routes commands to them.
"""

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Optional, Any

from starlette.websockets import WebSocket, WebSocketDisconnect

from homekit_mcp.auth import verify_token
from homekit_mcp.models.db.database import get_session
from homekit_mcp.models.db.repositories import DeviceRepository

logger = logging.getLogger(__name__)


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
    request_id: str
    device_id: str
    event: asyncio.Event = field(default_factory=asyncio.Event)
    response: Optional[Dict[str, Any]] = None
    error: Optional[str] = None


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

        # Update device status in database
        with get_session() as session:
            DeviceRepository.set_online(session, device_id)

        logger.info(f"Device connected: {device_id} (user: {auth.user_id})")

        # Send welcome message
        await websocket.send_json({
            "type": "connected",
            "device_id": device_id
        })

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

    async def send_command(
        self,
        device_id: str,
        command: str,
        params: Dict[str, Any],
        timeout: float = 30.0
    ) -> Dict[str, Any]:
        """
        Send a command to a device and wait for response.

        Args:
            device_id: Target device ID
            command: Command name (e.g., "list_homes", "control_accessory")
            params: Command parameters
            timeout: Timeout in seconds

        Returns:
            Response from the device

        Raises:
            ValueError: If device not connected
            TimeoutError: If response not received in time
        """
        if device_id not in self.connections:
            raise ValueError(f"Device {device_id} not connected")

        request_id = str(uuid.uuid4())
        pending = PendingRequest(request_id=request_id, device_id=device_id)

        async with self._lock:
            self.pending_requests[request_id] = pending

        try:
            # Send command to device
            conn = self.connections[device_id]
            await conn.websocket.send_json({
                "type": "command",
                "request_id": request_id,
                "command": command,
                "params": params
            })

            # Wait for response
            try:
                await asyncio.wait_for(pending.event.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                raise TimeoutError(f"Device {device_id} did not respond in time")

            if pending.error:
                raise ValueError(pending.error)

            return pending.response or {}

        finally:
            async with self._lock:
                self.pending_requests.pop(request_id, None)

    async def handle_message(self, device_id: str, message: Dict[str, Any]):
        """Handle an incoming message from a device."""
        msg_type = message.get("type")

        if msg_type == "response":
            # Response to a command
            request_id = message.get("request_id")
            if request_id and request_id in self.pending_requests:
                pending = self.pending_requests[request_id]
                pending.response = message.get("data")
                pending.event.set()

        elif msg_type == "error":
            # Error response
            request_id = message.get("request_id")
            if request_id and request_id in self.pending_requests:
                pending = self.pending_requests[request_id]
                pending.error = message.get("error", "Unknown error")
                pending.event.set()

        elif msg_type == "status":
            # Device status update
            home_count = message.get("home_count", 0)
            accessory_count = message.get("accessory_count", 0)

            with get_session() as session:
                DeviceRepository.set_online(
                    session, device_id,
                    home_count=home_count,
                    accessory_count=accessory_count
                )

        elif msg_type == "pong":
            # Keepalive response
            pass

        else:
            logger.warning(f"Unknown message type from {device_id}: {msg_type}")

    def is_connected(self, device_id: str) -> bool:
        """Check if a device is currently connected."""
        return device_id in self.connections

    def get_user_devices(self, user_id: uuid.UUID) -> list[str]:
        """Get all connected device IDs for a user."""
        return [
            device_id
            for device_id, conn in self.connections.items()
            if conn.user_id == user_id
        ]


# Global connection manager instance
connection_manager = ConnectionManager()


async def websocket_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for HomeKit Mac app connections.

    Query params:
        token: JWT authentication token
        device_id: Unique device identifier
    """
    # Get auth params from query string
    token = websocket.query_params.get("token")
    device_id = websocket.query_params.get("device_id")

    if not token or not device_id:
        await websocket.close(code=4000, reason="Missing token or device_id")
        return

    # Connect
    device = await connection_manager.connect(websocket, token, device_id)
    if not device:
        return

    try:
        # Message loop
        while True:
            data = await websocket.receive_text()

            try:
                message = json.loads(data)
                await connection_manager.handle_message(device_id, message)
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON from {device_id}: {data[:100]}")

    except WebSocketDisconnect:
        await connection_manager.disconnect(device_id)
    except Exception as e:
        logger.error(f"WebSocket error for {device_id}: {e}", exc_info=True)
        await connection_manager.disconnect(device_id)


async def ping_clients():
    """Periodically ping connected clients to keep connections alive."""
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
