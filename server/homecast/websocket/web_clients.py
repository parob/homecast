"""
WebSocket handler for web UI clients to receive real-time updates.

Broadcasts characteristic changes to all connected web clients.
Uses database to track sessions across multiple server instances.
"""

import asyncio
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Set, Any, Optional
import uuid

from starlette.websockets import WebSocket, WebSocketDisconnect

from homecast.auth import verify_token, extract_token_from_header
from homecast.models.db.database import get_session
from homecast.models.db.models import SessionType
from homecast.models.db.repositories import SessionRepository
from homecast.websocket.pubsub_router import router as pubsub_router

logger = logging.getLogger(__name__)


@dataclass
class WebClient:
    """A connected web browser client."""
    websocket: WebSocket
    user_id: uuid.UUID
    session_id: uuid.UUID  # Database session ID
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


class WebClientManager:
    """Manages WebSocket connections from web UI clients."""

    def __init__(self):
        # Local in-memory tracking for WebSocket connections on THIS instance
        # session_id -> WebClient
        self.local_clients: Dict[uuid.UUID, WebClient] = {}
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

    def _get_instance_id(self) -> str:
        """Get the current server instance ID."""
        return pubsub_router.instance_id if pubsub_router.enabled else "local"

    async def connect(self, websocket: WebSocket, token: str) -> Optional[WebClient]:
        """Accept and register a new web client connection."""
        auth = verify_token(token)
        if not auth:
            await websocket.accept()
            await websocket.close(code=4001, reason="Invalid token")
            return None

        await websocket.accept()

        # Check if user had any listeners BEFORE we add this one
        with get_session() as db:
            had_listeners = SessionRepository.has_web_listeners(db, auth.user_id)

            # Create session in database
            db_session = SessionRepository.create_session(
                db,
                user_id=auth.user_id,
                instance_id=self._get_instance_id(),
                session_type=SessionType.WEB,
                name="Web Browser"  # Could extract from User-Agent header
            )
            session_id = db_session.id

        client = WebClient(
            websocket=websocket,
            user_id=auth.user_id,
            session_id=session_id
        )

        # Track locally for broadcasting
        async with self.lock:
            self.local_clients[session_id] = client

        logger.info(f"Web client connected: user={auth.user_id}, session={session_id}")

        # Notify Mac app(s) if this is the first listener for this user
        if not had_listeners:
            await self._notify_mac_apps(auth.user_id, listening=True)

        return client

    async def disconnect(self, client: WebClient):
        """Handle client disconnection."""
        # Remove from local tracking
        async with self.lock:
            self.local_clients.pop(client.session_id, None)

        # Remove from database
        with get_session() as db:
            SessionRepository.delete_session(db, client.session_id)
            # Check if user still has listeners
            has_listeners = SessionRepository.has_web_listeners(db, client.user_id)

        logger.info(f"Web client disconnected: user={client.user_id}, session={client.session_id}")

        # Notify Mac app(s) if no more listeners
        if not has_listeners:
            await self._notify_mac_apps(client.user_id, listening=False)

    async def update_heartbeat(self, client: WebClient):
        """Update heartbeat for a client session."""
        with get_session() as db:
            SessionRepository.update_heartbeat(db, client.session_id)

    def has_listeners(self, user_id: uuid.UUID) -> bool:
        """Check if a user has any active web client sessions (across all instances)."""
        with get_session() as db:
            return SessionRepository.has_web_listeners(db, user_id)

    async def _notify_mac_apps(self, user_id: uuid.UUID, listening: bool):
        """Notify Mac app(s) for a user about web client listener status."""
        # Import here to avoid circular import
        from homecast.websocket.handler import connection_manager

        device_ids = connection_manager.get_user_devices(user_id)
        for device_id in device_ids:
            if device_id in connection_manager.connections:
                conn = connection_manager.connections[device_id]
                try:
                    await conn.websocket.send_json({
                        "type": "config",
                        "action": "listeners_changed",
                        "payload": {"webClientsListening": listening}
                    })
                    logger.info(f"Notified device {device_id}: webClientsListening={listening}")
                except Exception as e:
                    logger.error(f"Failed to notify device {device_id}: {e}")

    async def broadcast_to_user(self, user_id: uuid.UUID, message: Dict[str, Any]):
        """Broadcast a message to all LOCAL web clients for a user."""
        # Only broadcast to clients on THIS instance
        async with self.lock:
            clients = [c for c in self.local_clients.values() if c.user_id == user_id]

        if not clients:
            return

        disconnected = []
        for client in clients:
            try:
                await client.websocket.send_json(message)
            except Exception:
                disconnected.append(client)

        for client in disconnected:
            await self.disconnect(client)

    async def broadcast_characteristic_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        characteristic_type: str,
        value: Any
    ):
        """Broadcast a characteristic update to all web clients for a user."""
        await self.broadcast_to_user(user_id, {
            "type": "characteristic_update",
            "accessoryId": accessory_id,
            "characteristicType": characteristic_type,
            "value": value
        })

    async def broadcast_reachability_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        is_reachable: bool
    ):
        """Broadcast a reachability update to all web clients for a user."""
        await self.broadcast_to_user(user_id, {
            "type": "reachability_update",
            "accessoryId": accessory_id,
            "isReachable": is_reachable
        })


# Global instance
web_client_manager = WebClientManager()


async def cleanup_stale_sessions():
    """Periodically clean up stale sessions from database."""
    while True:
        await asyncio.sleep(60)  # Run every minute
        try:
            with get_session() as db:
                SessionRepository.cleanup_stale_sessions(db)
        except Exception as e:
            logger.error(f"Error cleaning up stale sessions: {e}")


async def cleanup_instance_sessions():
    """Clean up all sessions for this instance (on shutdown)."""
    instance_id = web_client_manager._get_instance_id()
    try:
        with get_session() as db:
            SessionRepository.cleanup_instance_sessions(db, instance_id)
    except Exception as e:
        logger.error(f"Error cleaning up instance sessions: {e}")


async def web_client_endpoint(websocket: WebSocket):
    """WebSocket endpoint for web UI clients."""
    # Get auth token from query param
    token = websocket.query_params.get("token")

    if not token:
        await websocket.accept()
        await websocket.close(code=4000, reason="Missing token")
        return

    client = await web_client_manager.connect(websocket, token)
    if not client:
        return

    # Start a background task to send server-initiated pings
    async def ping_task():
        while True:
            await asyncio.sleep(30)  # Ping every 30 seconds
            try:
                await websocket.send_json({"type": "ping"})
                await web_client_manager.update_heartbeat(client)
            except Exception:
                break  # Connection closed

    ping_task_handle = asyncio.create_task(ping_task())

    try:
        # Keep connection alive, handle messages
        while True:
            try:
                # Use a timeout to detect dead connections
                data = await asyncio.wait_for(websocket.receive_text(), timeout=90)
            except asyncio.TimeoutError:
                logger.warning(f"Web client {client.session_id} timed out - no message in 90s")
                break

            try:
                message = json.loads(data)
                msg_type = message.get("type")
                if msg_type == "ping":
                    # Client-initiated ping - update heartbeat and respond
                    await web_client_manager.update_heartbeat(client)
                    await websocket.send_json({"type": "pong"})
                elif msg_type == "pong":
                    # Response to our server-initiated ping
                    await web_client_manager.update_heartbeat(client)
            except json.JSONDecodeError:
                pass
    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error(f"Web client error: {e}")
    finally:
        ping_task_handle.cancel()
        await web_client_manager.disconnect(client)
