"""
WebSocket handler for web UI clients to receive real-time updates.

Broadcasts characteristic changes to all connected web clients.
Uses database to track sessions across multiple server instances.

Also handles share subscriptions for anonymous users viewing shared entities.
"""

import asyncio
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Set, Any, Optional, List, Tuple
import uuid

from starlette.websockets import WebSocket, WebSocketDisconnect

from homecast.auth import verify_token, extract_token_from_header
from homecast.models.db.database import get_session
from homecast.models.db.models import SessionType
from homecast.models.db.repositories import SessionRepository, EntityAccessRepository, StoredEntityRepository
from homecast.websocket.pubsub_router import router as pubsub_router

logger = logging.getLogger(__name__)


@dataclass
class WebClient:
    """A connected web browser client (authenticated)."""
    websocket: WebSocket
    user_id: uuid.UUID
    session_id: uuid.UUID  # Database session ID
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class ShareSubscription:
    """Tracks a client's subscription to a shared entity."""
    client_id: str
    share_hash: str
    entity_type: str
    entity_id: uuid.UUID
    owner_id: uuid.UUID
    role: str  # "view" or "control"
    accessory_ids: List[str]  # Only these accessories can be sent to client
    subscribed_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class SharedViewClient:
    """A connected anonymous client viewing a shared entity."""
    websocket: WebSocket
    client_id: str  # Random ID for this connection
    connected_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


class WebClientManager:
    """Manages WebSocket connections from web UI clients and shared view clients."""

    def __init__(self):
        # Local in-memory tracking for WebSocket connections on THIS instance
        # session_id -> WebClient (authenticated users)
        self.local_clients: Dict[uuid.UUID, WebClient] = {}

        # Shared view clients (anonymous, viewing shared entities)
        # client_id -> SharedViewClient
        self.shared_view_clients: Dict[str, SharedViewClient] = {}

        # Share subscriptions: share_hash -> {client_id -> ShareSubscription}
        self.share_subscriptions: Dict[str, Dict[str, ShareSubscription]] = {}

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

    # --- Shared View Client Methods ---

    async def connect_shared_view(self, websocket: WebSocket) -> SharedViewClient:
        """Accept and register a new shared view client (no auth required)."""
        await websocket.accept()

        client_id = str(uuid.uuid4())
        client = SharedViewClient(
            websocket=websocket,
            client_id=client_id
        )

        async with self.lock:
            self.shared_view_clients[client_id] = client

        logger.info(f"Shared view client connected: {client_id}")
        return client

    async def disconnect_shared_view(self, client: SharedViewClient):
        """Handle shared view client disconnection."""
        # Remove all subscriptions for this client
        async with self.lock:
            self.shared_view_clients.pop(client.client_id, None)

            # Remove from all share subscriptions
            for share_hash in list(self.share_subscriptions.keys()):
                if client.client_id in self.share_subscriptions[share_hash]:
                    del self.share_subscriptions[share_hash][client.client_id]
                    if not self.share_subscriptions[share_hash]:
                        del self.share_subscriptions[share_hash]

        logger.info(f"Shared view client disconnected: {client.client_id}")

    async def subscribe_to_share(
        self,
        client_id: str,
        share_hash: str,
        passcode: Optional[str] = None
    ) -> Tuple[bool, Optional[str]]:
        """
        Subscribe a shared view client to updates for a share hash.

        SECURITY: Verifies access before allowing subscription.

        Returns:
            (success, error_message)
        """
        # CRITICAL: Verify access at backend level
        with get_session() as session:
            access, entity_type, entity_id = EntityAccessRepository.verify_access_by_hash(
                session, share_hash, passcode, user_id=None
            )

            if not access:
                logger.warning(f"Share subscription denied: invalid access for {share_hash}")
                return (False, "Access denied")

            # Get accessory IDs from collection payload (for filtering updates)
            accessory_ids: List[str] = []
            if entity_type == "collection":
                collection_entity = StoredEntityRepository.get_entity(
                    session, access.owner_id, 'collection', str(entity_id)
                )
                if collection_entity:
                    try:
                        data = json.loads(collection_entity.data_json) if collection_entity.data_json else {}
                        items = data.get("items", [])
                        accessory_ids = [
                            item["accessory_id"] for item in items
                            if item.get("accessory_id")
                        ]
                    except json.JSONDecodeError:
                        pass

            # Create subscription with verified data
            subscription = ShareSubscription(
                client_id=client_id,
                share_hash=share_hash,
                entity_type=entity_type,
                entity_id=entity_id,
                owner_id=access.owner_id,  # From database, not client
                role=access.role,
                accessory_ids=accessory_ids,
            )

            async with self.lock:
                if share_hash not in self.share_subscriptions:
                    self.share_subscriptions[share_hash] = {}
                self.share_subscriptions[share_hash][client_id] = subscription

            logger.info(f"Share subscription added: {client_id} -> {share_hash} ({len(accessory_ids)} accessories)")
            return (True, None)

    async def unsubscribe_from_share(self, client_id: str, share_hash: str):
        """Unsubscribe a shared view client from a share hash."""
        async with self.lock:
            if share_hash in self.share_subscriptions:
                self.share_subscriptions[share_hash].pop(client_id, None)
                if not self.share_subscriptions[share_hash]:
                    del self.share_subscriptions[share_hash]

    async def unsubscribe_all_from_share(self, share_hash: str):
        """
        Unsubscribe ALL clients from a share hash.

        Called when access is revoked/deleted.
        """
        async with self.lock:
            if share_hash in self.share_subscriptions:
                client_ids = list(self.share_subscriptions[share_hash].keys())
                del self.share_subscriptions[share_hash]
                logger.info(f"Revoked {len(client_ids)} subscriptions for {share_hash}")

    async def broadcast_to_share_subscribers(
        self,
        owner_id: uuid.UUID,
        accessory_id: str,
        message: Dict[str, Any]
    ):
        """
        Send accessory update to share subscribers.

        SECURITY: Only sends to subscribers where:
        1. The owner_id matches the subscription's owner_id
        2. The accessory_id is in the subscription's allowed list
        """
        disconnected_clients: List[str] = []

        async with self.lock:
            subscriptions_snapshot = [
                (share_hash, sub)
                for share_hash, subs in self.share_subscriptions.items()
                for sub in subs.values()
            ]

        for share_hash, sub in subscriptions_snapshot:
            # SECURITY CHECK 1: Owner must match
            if sub.owner_id != owner_id:
                continue

            # SECURITY CHECK 2: Accessory must be in allowed list
            if accessory_id not in sub.accessory_ids:
                continue

            # Get client and send
            client = self.shared_view_clients.get(sub.client_id)
            if client:
                try:
                    await client.websocket.send_json(message)
                except Exception:
                    disconnected_clients.append(sub.client_id)

        # Clean up disconnected clients
        for client_id in disconnected_clients:
            client = self.shared_view_clients.get(client_id)
            if client:
                await self.disconnect_shared_view(client)


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

    # Send connection info with server instance details
    instance_id = web_client_manager._get_instance_id()
    await websocket.send_json({
        "type": "connected",
        "serverInstanceId": instance_id,
        "pubsubEnabled": pubsub_router.enabled,
        "pubsubSlot": pubsub_router._slot_name if pubsub_router.enabled else None
    })

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


async def shared_view_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for shared view clients (no auth required).

    Handles subscribe/unsubscribe messages for share hash subscriptions.
    """
    client = await web_client_manager.connect_shared_view(websocket)

    # Start a background task to send server-initiated pings
    async def ping_task():
        while True:
            await asyncio.sleep(30)  # Ping every 30 seconds
            try:
                await websocket.send_json({"type": "ping"})
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
                logger.warning(f"Shared view client {client.client_id} timed out - no message in 90s")
                break

            try:
                message = json.loads(data)
                msg_type = message.get("type")

                if msg_type == "ping":
                    await websocket.send_json({"type": "pong"})

                elif msg_type == "pong":
                    pass  # Response to our ping

                elif msg_type == "subscribe":
                    # Subscribe to a share hash
                    share_hash = message.get("shareHash")
                    passcode = message.get("passcode")

                    if not share_hash:
                        await websocket.send_json({
                            "type": "subscribe_error",
                            "error": "Missing shareHash"
                        })
                        continue

                    success, error = await web_client_manager.subscribe_to_share(
                        client.client_id, share_hash, passcode
                    )

                    if success:
                        await websocket.send_json({
                            "type": "subscribed",
                            "shareHash": share_hash
                        })
                    else:
                        await websocket.send_json({
                            "type": "subscribe_error",
                            "shareHash": share_hash,
                            "error": error or "Access denied"
                        })

                elif msg_type == "unsubscribe":
                    # Unsubscribe from a share hash
                    share_hash = message.get("shareHash")
                    if share_hash:
                        await web_client_manager.unsubscribe_from_share(
                            client.client_id, share_hash
                        )
                        await websocket.send_json({
                            "type": "unsubscribed",
                            "shareHash": share_hash
                        })

            except json.JSONDecodeError:
                pass

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error(f"Shared view client error: {e}")
    finally:
        ping_task_handle.cancel()
        await web_client_manager.disconnect_shared_view(client)
