"""
Pub/Sub based routing for distributed Cloud Run instances.

Uses a pool of topic slots to avoid creating unlimited topics:
1. On startup, instance claims an available slot from the database
2. Topics are named: {prefix}-{slot_name} (e.g., homecast-instance-a7f2)
3. Stale slots (instance died) are reclaimed after 5 minutes
4. Device.instance_id stores the slot_name, not the Cloud Run revision

Setup:
1. Set GCP_PROJECT_ID environment variable
2. Cloud Run service account needs Pub/Sub Admin role
"""

import asyncio
import json
import logging
import os
import uuid
import concurrent.futures
from concurrent.futures import Future as ThreadFuture
from typing import Any, Callable, Dict, List, Optional

from homecast import config
from homecast.models.db.database import get_session
from homecast.models.db.repositories import SessionRepository, TopicSlotRepository

# Conditional import for catching Pub/Sub NotFound exceptions
try:
    from google.api_core.exceptions import NotFound
except ImportError:
    class NotFound(Exception):  # type: ignore[no-redef]
        """Dummy class for when google-cloud is not installed."""
        pass

logger = logging.getLogger(__name__)

# Unique container instance ID from Cloud Run metadata (resolved lazily)
_instance_id: Optional[str] = None

def _get_instance_id() -> str:
    """Get unique instance ID from Cloud Run metadata server."""
    global _instance_id
    if _instance_id is not None:
        return _instance_id

    import urllib.request
    revision = os.getenv("K_REVISION", "local")

    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/id",
        headers={"Metadata-Flavor": "Google"}
    )
    with urllib.request.urlopen(req, timeout=2) as response:
        metadata_id = response.read().decode("utf-8")
        _instance_id = f"{revision}-{metadata_id[-8:]}"
        logger.info(f"Instance ID: {_instance_id}")
        return _instance_id


class PubSubRouter:
    """
    Routes WebSocket messages between Cloud Run instances via Pub/Sub.

    Uses pooled topic slots from the database instead of per-revision topics.
    """

    # Buffer configuration
    BUFFER_FLUSH_DELAY_MS = 200
    MAX_BUFFER_SIZE = 50

    def __init__(self):
        self._publisher = None
        self._subscriber = None
        self._subscription_future = None
        self._pending_requests: Dict[str, ThreadFuture] = {}
        self._local_handler: Optional[Callable] = None
        self._local_device_checker: Optional[Callable[[str], bool]] = None
        self._enabled = bool(config.GCP_PROJECT_ID)
        self._topic_path = None
        self._subscription_path = None
        self._loop = None
        self._project_id = None
        self._slot_name: Optional[str] = None
        self._heartbeat_task: Optional[asyncio.Task] = None

        # Buffering for batched updates
        self._update_buffers: Dict[str, List[dict]] = {}  # user_id -> list of updates
        self._flush_tasks: Dict[str, asyncio.Task] = {}  # user_id -> scheduled flush task

    @property
    def enabled(self) -> bool:
        return self._enabled

    @property
    def instance_id(self) -> str:
        """Returns the unique container instance ID."""
        return _get_instance_id()

    @property
    def slot_name(self) -> Optional[str]:
        """Returns the Pub/Sub topic slot claimed by this instance."""
        return self._slot_name

    def _get_topic_name(self, slot_name: str) -> str:
        """Get topic name for a slot."""
        return f"{config.GCP_PUBSUB_TOPIC_PREFIX}-{slot_name}"

    def _get_topic_path(self, slot_name: str) -> str:
        """Get full topic path for a slot."""
        return self._publisher.topic_path(self._project_id, self._get_topic_name(slot_name))

    def _handle_deleted_topic(self, slot_name: str) -> None:
        """Remove a slot from DB when its topic has been deleted."""
        logger.warning(f"Cleaning up deleted topic slot: {slot_name}")
        try:
            with get_session() as session:
                TopicSlotRepository.delete_slot_by_name(session, slot_name)
        except Exception as e:
            logger.error(f"Failed to cleanup slot {slot_name}: {e}")

    def _find_orphaned_topic(self) -> Optional[str]:
        """Find an existing topic not tracked in the database."""
        prefix = f"projects/{self._project_id}/topics/{config.GCP_PUBSUB_TOPIC_PREFIX}-"

        # Get all slot names from database
        with get_session() as session:
            tracked_slots = TopicSlotRepository.get_all_slot_names(session)

        # List all topics in GCP matching our prefix
        for topic in self._publisher.list_topics(request={"project": f"projects/{self._project_id}"}):
            if topic.name.startswith(prefix):
                # Extract slot name from topic path
                slot_name = topic.name.split("-")[-1]
                if slot_name not in tracked_slots:
                    logger.info(f"Found orphaned topic with slot: {slot_name}")
                    return slot_name

        return None

    async def connect(self):
        """Connect to Pub/Sub and start listening for messages."""
        if not self._enabled:
            logger.info("GCP_PROJECT_ID not configured - running in local-only mode")
            return

        try:
            from google.cloud import pubsub_v1
            from google.api_core.exceptions import AlreadyExists, NotFound
            from google.protobuf.duration_pb2 import Duration

            self._project_id = config.GCP_PROJECT_ID
            self._loop = asyncio.get_event_loop()

            # Initialize Pub/Sub publisher first (needed to search for orphaned topics)
            self._publisher = pubsub_v1.PublisherClient()

            # Check for orphaned topics before claiming a slot
            orphaned_slot = self._find_orphaned_topic()
            if orphaned_slot:
                # Create DB record for orphaned topic
                with get_session() as session:
                    slot = TopicSlotRepository.claim_or_create_slot(session, _get_instance_id(), orphaned_slot)
                    self._slot_name = slot.slot_name
                logger.info(f"Recovered orphaned topic slot: {self._slot_name}")
            else:
                # Normal slot claiming flow
                with get_session() as session:
                    slot = TopicSlotRepository.claim_slot(session, _get_instance_id())
                    self._slot_name = slot.slot_name
                logger.info(f"Claimed topic slot: {self._slot_name} (instance: {_get_instance_id()})")

            self._topic_path = self._get_topic_path(self._slot_name)

            # Create topic for this slot (or reuse existing)
            try:
                self._publisher.create_topic(request={"name": self._topic_path})
                logger.info(f"Created topic: {self._get_topic_name(self._slot_name)}")
            except AlreadyExists:
                logger.info(f"Using existing topic: {self._get_topic_name(self._slot_name)}")

            # Initialize Pub/Sub subscriber
            self._subscriber = pubsub_v1.SubscriberClient()
            subscription_name = f"{config.GCP_PUBSUB_TOPIC_PREFIX}-{self._slot_name}-sub"
            self._subscription_path = self._subscriber.subscription_path(self._project_id, subscription_name)

            # Create subscription for this slot
            try:
                self._subscriber.create_subscription(
                    request={
                        "name": self._subscription_path,
                        "topic": self._topic_path,
                        "ack_deadline_seconds": 30,
                        "message_retention_duration": Duration(seconds=600),
                    }
                )
                logger.info(f"Created subscription: {subscription_name}")
            except AlreadyExists:
                logger.info(f"Using existing subscription: {subscription_name}")

            # Start listening for messages
            self._subscription_future = self._subscriber.subscribe(
                self._subscription_path,
                callback=self._message_callback
            )
            logger.info(f"Listening for messages on slot {self._slot_name}")

            # Start heartbeat task to keep slot alive
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())

            logger.info(f"Pub/Sub router initialized (instance: {_get_instance_id()}, slot: {self._slot_name})")

        except Exception as e:
            logger.error(f"Failed to initialize Pub/Sub router: {e}", exc_info=True)
            self._enabled = False

    async def _heartbeat_loop(self):
        """Send periodic heartbeats to keep slot claimed."""
        try:
            while True:
                await asyncio.sleep(60)  # Every minute
                with get_session() as session:
                    TopicSlotRepository.heartbeat(session, _get_instance_id())
                logger.debug(f"Slot heartbeat: {self._slot_name}")
        except asyncio.CancelledError:
            pass

    def _message_callback(self, message):
        """Sync callback from Pub/Sub - schedules async handling."""
        try:
            data = json.loads(message.data.decode("utf-8"))
            msg_type = data.get("type", "unknown")
            correlation_id = data.get("correlation_id", "")[:8]
            source_slot = data.get("source_slot", "?")
            device_id = data.get("device_id", "")[:8] if data.get("device_id") else "?"
            action = data.get("action", "?")

            if msg_type == "request":
                logger.info(f"Received Pub/Sub REQUEST: action={action}, device={device_id}, from={source_slot}, correlation={correlation_id}")
            elif msg_type == "response":
                logger.info(f"Received Pub/Sub RESPONSE: correlation={correlation_id}")
            else:
                logger.info(f"Received Pub/Sub message: type={msg_type}, correlation={correlation_id}")

            if self._loop and self._loop.is_running():
                asyncio.run_coroutine_threadsafe(self._handle_message(data), self._loop)
            else:
                logger.error(f"Event loop not available! loop={self._loop}, running={self._loop.is_running() if self._loop else 'N/A'}")

            message.ack()
        except Exception as e:
            logger.error(f"Error processing Pub/Sub message: {e}", exc_info=True)
            message.nack()

    async def disconnect(self):
        """Disconnect and cleanup."""
        # Stop heartbeat
        if self._heartbeat_task:
            self._heartbeat_task.cancel()
            try:
                await self._heartbeat_task
            except asyncio.CancelledError:
                pass

        # Stop subscription
        if self._subscription_future:
            self._subscription_future.cancel()
            try:
                self._subscription_future.result(timeout=5)
            except Exception:
                pass

        # Release slot
        if self._slot_name:
            with get_session() as session:
                TopicSlotRepository.release_slot(session, _get_instance_id())
            logger.info(f"Released slot: {self._slot_name}")

        logger.info("Pub/Sub router disconnected")

    def set_local_handler(self, handler: Callable):
        """Set the handler for requests to local devices."""
        self._local_handler = handler

    def set_local_device_checker(self, checker: Callable[[str], bool]):
        """Set a function that checks if a device is connected to this instance."""
        self._local_device_checker = checker

    async def send_request(
        self,
        device_id: str,
        action: str,
        payload: Dict[str, Any],
        timeout: float = 30.0,
        is_retry: bool = False
    ) -> Dict[str, Any]:
        """
        Send a request to a device, routing via Pub/Sub if needed.

        If the target instance reports DEVICE_NOT_HERE (stale routing), this
        will refresh the session and retry once.
        """
        if not self._enabled:
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Check local connections first (fast path - avoids DB lookup)
        if self._local_device_checker and self._local_device_checker(device_id):
            logger.info(f"[{action}] Device {device_id[:8]} is LOCAL, handling directly")
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Look up device session from database
        logger.info(f"[{action}] Device {device_id[:8]} not local, looking up session...")
        with get_session() as db:
            session_record = SessionRepository.get_device_session(db, device_id, include_stale=False)
            if not session_record:
                logger.warning(f"[{action}] Device {device_id[:8]} session not found (stale or doesn't exist)")
                raise ValueError(f"Device {device_id} not connected")

            device_instance_id = session_record.instance_id
            logger.info(f"[{action}] Device {device_id[:8]} session found: instance_id={device_instance_id}, last_heartbeat={session_record.last_heartbeat}")

        if not device_instance_id:
            raise ValueError(f"Device {device_id} has no instance_id")

        my_instance_id = _get_instance_id()
        # Double-check: if device is on this instance, handle locally
        if device_instance_id == my_instance_id:
            logger.info(f"[{action}] Device {device_id[:8]} is on THIS instance ({my_instance_id}), but not in local connections - handling locally anyway")
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        logger.info(f"[{action}] Device {device_id[:8]} is on REMOTE instance: {device_instance_id} (we are {my_instance_id})")

        # Look up which slot the target instance has claimed
        with get_session() as db:
            target_slot_record = TopicSlotRepository.get_slot_for_instance(db, device_instance_id)
            if not target_slot_record:
                # Instance has no slot = it died, invalidate session and retry
                if not is_retry:
                    invalidated = SessionRepository.invalidate_instance_for_device(db, device_id, device_instance_id)
                    if invalidated:
                        logger.info(f"Instance {device_instance_id} has no slot, invalidated session, retrying...")
                        return await self.send_request(device_id, action, payload, timeout, is_retry=True)
                raise ValueError(f"Instance {device_instance_id} has no active slot")
            target_slot = target_slot_record.slot_name

        # Route to remote instance via Pub/Sub
        correlation_id = str(uuid.uuid4())

        # Use concurrent.futures.Future - works across threads without event loop issues
        future: ThreadFuture = ThreadFuture()
        self._pending_requests[correlation_id] = future

        logger.info(f"Routing request {correlation_id[:8]}: {self._slot_name} -> {target_slot} (instance: {device_instance_id}, device: {device_id}, action: {action})")

        try:
            target_topic = self._get_topic_path(target_slot)

            message_data = json.dumps({
                "type": "request",
                "correlation_id": correlation_id,
                "source_slot": self._slot_name,
                "device_id": device_id,
                "action": action,
                "payload": payload
            }).encode("utf-8")

            try:
                self._publisher.publish(target_topic, message_data).result(timeout=5)
                logger.info(f"Published request {correlation_id[:8]} to topic {target_topic}")
            except NotFound:
                logger.warning(f"Topic not found for slot {target_slot} - cleaning up")
                self._handle_deleted_topic(target_slot)
                # Topic deleted = dead instance, invalidate session and retry
                if not is_retry:
                    with get_session() as db:
                        invalidated = SessionRepository.invalidate_instance_for_device(db, device_id, device_instance_id)
                        if invalidated:
                            logger.info(f"[{correlation_id[:8]}] Topic gone, invalidated session, retrying...")
                            return await self.send_request(device_id, action, payload, timeout, is_retry=True)
                raise ValueError(f"Target instance slot {target_slot} no longer exists")
            except Exception as e:
                raise ValueError(f"Failed to route to slot {target_slot}: {e}")

            # Wait for result using run_in_executor (ThreadFuture.result blocks)
            loop = asyncio.get_running_loop()
            logger.info(f"[{correlation_id[:8]}] Waiting for response (timeout={timeout}s)...")
            try:
                result = await loop.run_in_executor(None, future.result, timeout)
                logger.info(f"[{correlation_id[:8]}] Response received!")
            except concurrent.futures.TimeoutError:
                pending_keys = [k[:8] for k in list(self._pending_requests.keys())]
                logger.error(f"[{correlation_id[:8]}] TIMEOUT after {timeout}s waiting for device {device_id[:8]}. Pending requests: {pending_keys}")

                # Timeout may indicate dead instance - invalidate session so retry routes elsewhere
                if not is_retry:
                    with get_session() as db:
                        invalidated = SessionRepository.invalidate_instance_for_device(db, device_id, device_instance_id)
                        if invalidated:
                            logger.info(f"[{correlation_id[:8]}] Invalidated stale instance {device_instance_id} after timeout, retrying...")
                            return await self.send_request(device_id, action, payload, timeout, is_retry=True)

                raise TimeoutError(f"Device {device_id} did not respond within {timeout}s")
            except Exception as e:
                raise ValueError(f"Request failed: {type(e).__name__}: {e}")

            if "error" in result:
                error_code = result["error"].get("code")
                error_message = result["error"].get("message", "Unknown error")

                # If device moved to a different instance, retry once with fresh session lookup
                if error_code == "DEVICE_NOT_HERE" and not is_retry:
                    logger.info(f"[{correlation_id[:8]}] Device not at expected instance, refreshing session and retrying...")
                    # Retry will do a fresh session lookup from the database
                    return await self.send_request(device_id, action, payload, timeout, is_retry=True)

                raise ValueError(error_message)

            return result.get("payload", {})
        finally:
            self._pending_requests.pop(correlation_id, None)

    async def send_ping(
        self,
        device_id: str,
        timeout: float = 10.0
    ) -> Dict[str, Any]:
        """
        Send a ping to a device, routing via Pub/Sub if needed.

        Returns:
            Dict with 'success', 'latency_ms', and optionally 'error'
        """
        if not self._enabled:
            return {"success": False, "error": "Pub/Sub not enabled"}

        # Check local connections first (fast path)
        if self._local_device_checker and self._local_device_checker(device_id):
            logger.info(f"[ping] Device {device_id[:8]} is LOCAL, pinging directly")
            from homecast.websocket.handler import connection_manager
            return await connection_manager.ping_device(device_id, timeout)

        # Look up device session from database
        logger.info(f"[ping] Device {device_id[:8]} not local, looking up session...")
        with get_session() as db:
            session_record = SessionRepository.get_device_session(db, device_id, include_stale=False)
            if not session_record:
                return {"success": False, "error": "Device not connected"}

            device_instance_id = session_record.instance_id

        if not device_instance_id:
            return {"success": False, "error": "Device has no instance_id"}

        # If device is on this instance but not in local connections, it may have just disconnected
        my_instance_id = _get_instance_id()
        if device_instance_id == my_instance_id:
            return {"success": False, "error": "Device session stale - not actually connected"}

        # Look up which slot the target instance has claimed
        with get_session() as db:
            target_slot_record = TopicSlotRepository.get_slot_for_instance(db, device_instance_id)
            if not target_slot_record:
                return {"success": False, "error": f"Instance {device_instance_id} has no active slot"}
            target_slot = target_slot_record.slot_name

        # Route to remote instance via Pub/Sub
        correlation_id = str(uuid.uuid4())
        future: ThreadFuture = ThreadFuture()
        self._pending_requests[correlation_id] = future

        logger.info(f"Routing ping {correlation_id[:8]}: {self._slot_name} -> {target_slot} (device: {device_id})")

        try:
            target_topic = self._get_topic_path(target_slot)

            message_data = json.dumps({
                "type": "ping_request",
                "correlation_id": correlation_id,
                "source_slot": self._slot_name,
                "device_id": device_id
            }).encode("utf-8")

            try:
                self._publisher.publish(target_topic, message_data).result(timeout=5)
                logger.info(f"Published ping request {correlation_id[:8]} to topic {target_topic}")
            except NotFound:
                logger.warning(f"Topic not found for slot {target_slot}")
                self._handle_deleted_topic(target_slot)
                return {"success": False, "error": "Target instance no longer exists"}
            except Exception as e:
                return {"success": False, "error": f"Failed to route ping: {e}"}

            # Wait for result
            loop = asyncio.get_running_loop()
            try:
                result = await loop.run_in_executor(None, future.result, timeout)
            except concurrent.futures.TimeoutError:
                return {"success": False, "error": f"Ping timeout - no response within {timeout}s"}
            except Exception as e:
                return {"success": False, "error": f"Ping failed: {e}"}

            return result

        finally:
            self._pending_requests.pop(correlation_id, None)

    async def _add_to_buffer(self, user_id: str, update: dict):
        """Add an update to the buffer for a user, scheduling a flush."""
        if user_id not in self._update_buffers:
            self._update_buffers[user_id] = []

        self._update_buffers[user_id].append(update)

        # Cancel existing timer and reschedule
        if user_id in self._flush_tasks:
            self._flush_tasks[user_id].cancel()

        # Force flush if buffer too large
        if len(self._update_buffers[user_id]) >= self.MAX_BUFFER_SIZE:
            await self._flush_buffer(user_id)
        else:
            # Schedule flush after delay
            self._flush_tasks[user_id] = asyncio.create_task(
                self._delayed_flush(user_id)
            )

    async def _delayed_flush(self, user_id: str):
        """Wait for buffer delay then flush."""
        try:
            await asyncio.sleep(self.BUFFER_FLUSH_DELAY_MS / 1000.0)
            await self._flush_buffer(user_id)
        except asyncio.CancelledError:
            pass  # Timer was cancelled, new update came in

    async def _flush_buffer(self, user_id: str):
        """Flush all buffered updates for a user as a single batch message."""
        if user_id not in self._update_buffers or not self._update_buffers[user_id]:
            return

        updates = self._update_buffers.pop(user_id, [])
        self._flush_tasks.pop(user_id, None)

        if not updates:
            return

        # Get all instance_ids that have web clients for this user
        with get_session() as db:
            instance_ids = SessionRepository.get_web_client_instance_ids(db, uuid.UUID(user_id))

            if not instance_ids:
                logger.debug(f"No web client instances for user {user_id}")
                return

            # Get slot names for each instance (excluding our own - we handle locally)
            my_instance_id = _get_instance_id()
            target_slots = []

            for instance_id in instance_ids:
                if instance_id == my_instance_id:
                    continue  # Skip our own instance - handled locally
                slot = TopicSlotRepository.get_slot_for_instance(db, instance_id)
                if slot:
                    target_slots.append(slot.slot_name)

        if not target_slots:
            logger.debug(f"No remote instances to broadcast batch to for user {user_id}")
            return

        # Send batched updates to each target instance's topic
        message_data = json.dumps({
            "type": "batch",
            "user_id": user_id,
            "updates": updates
        }).encode("utf-8")

        for slot_name in target_slots:
            try:
                target_topic = self._get_topic_path(slot_name)
                self._publisher.publish(target_topic, message_data).result(timeout=5)
                logger.info(f"Broadcast batch of {len(updates)} updates to slot {slot_name}")
            except NotFound:
                logger.warning(f"Topic not found for slot {slot_name} - cleaning up")
                self._handle_deleted_topic(slot_name)
            except Exception as e:
                logger.error(f"Failed to broadcast batch to slot {slot_name}: {e}")

    async def broadcast_characteristic_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        characteristic_type: str,
        value: Any
    ):
        """
        Broadcast a characteristic update to all instances with web clients for this user.

        Updates are buffered and sent as batches to reduce Pub/Sub message count.
        """
        if not self._enabled:
            # Local-only mode - web_client_manager handles it directly
            return

        # Add to buffer for batched sending
        update = {
            "type": "characteristic_update",
            "accessory_id": accessory_id,
            "characteristic_type": characteristic_type,
            "value": value
        }
        await self._add_to_buffer(str(user_id), update)

    async def broadcast_reachability_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        is_reachable: bool
    ):
        """
        Broadcast a reachability update to all instances with web clients for this user.

        Updates are buffered and sent as batches to reduce Pub/Sub message count.
        """
        if not self._enabled:
            # Local-only mode - web_client_manager handles it directly
            return

        # Add to buffer for batched sending
        update = {
            "type": "reachability_update",
            "accessory_id": accessory_id,
            "is_reachable": is_reachable
        }
        await self._add_to_buffer(str(user_id), update)

    def _resolve_future(self, correlation_id: str, data: Dict[str, Any]):
        """Thread-safe resolution of a pending future."""
        if correlation_id not in self._pending_requests:
            logger.warning(f"No pending request for correlation_id {correlation_id[:8]}")
            return

        future = self._pending_requests[correlation_id]
        if future.done():
            logger.warning(f"Future already done for {correlation_id[:8]}")
            return

        # ThreadFuture.set_result is thread-safe
        future.set_result(data)
        logger.info(f"Resolved Future for {correlation_id[:8]}")

    async def _handle_message(self, data: Dict[str, Any]):
        """Handle an incoming Pub/Sub message."""
        msg_type = data.get("type")
        correlation_id = data.get("correlation_id")

        if msg_type == "response":
            pending_keys = [k[:8] for k in list(self._pending_requests.keys())[:3]]
            logger.info(f"Processing response {correlation_id[:8] if correlation_id else 'none'}, pending={pending_keys}")
            if correlation_id:
                self._resolve_future(correlation_id, data)

        elif msg_type == "request":
            await self._handle_remote_request(data)

        elif msg_type == "characteristic_update":
            await self._handle_characteristic_update(data)

        elif msg_type == "reachability_update":
            await self._handle_reachability_update(data)

        elif msg_type == "batch":
            await self._handle_batch_update(data)

        elif msg_type == "ping_request":
            await self._handle_remote_ping_request(data)

        else:
            logger.warning(f"Unknown message type: {msg_type}")

    async def _handle_remote_request(self, data: Dict[str, Any]):
        """Handle a request routed from another instance."""
        correlation_id = data["correlation_id"]
        source_slot = data["source_slot"]
        device_id = data["device_id"]
        action = data["action"]
        payload = data.get("payload", {})

        # Check if device is actually connected to this instance
        is_local = self._local_device_checker(device_id) if self._local_device_checker else False
        logger.info(f"Handling remote request {correlation_id[:8]}: device={device_id[:8]}, action={action}, reply_to={source_slot}, device_is_local={is_local}")

        # Fail fast: if device isn't actually connected here, return error immediately
        # This happens when session.instance_id is stale (device moved or instance died)
        if not is_local:
            logger.warning(f"[{correlation_id[:8]}] Device {device_id[:8]} routed here but NOT in local connections!")

            # Invalidate the stale session so retry can find the device's actual location
            with get_session() as db:
                SessionRepository.invalidate_instance_for_device(db, device_id, _get_instance_id())

            response = {
                "type": "response",
                "correlation_id": correlation_id,
                "error": {"code": "DEVICE_NOT_HERE", "message": f"Device {device_id} not connected to this instance"}
            }
            # Send error response back to source slot
            source_topic = self._get_topic_path(source_slot)
            message_data = json.dumps(response).encode("utf-8")
            try:
                self._publisher.publish(source_topic, message_data).result(timeout=5)
                logger.info(f"Sent DEVICE_NOT_HERE error response {correlation_id[:8]} to slot {source_slot}")
            except NotFound:
                logger.warning(f"Topic not found for slot {source_slot} - cleaning up")
                self._handle_deleted_topic(source_slot)
            except Exception as e:
                logger.error(f"Failed to publish error response to slot {source_slot}: {e}")
            return

        # Add routing metadata for the Mac app to see the journey
        # source_slot tells us which Pub/Sub slot the request came from
        # We look up the instance that owns that slot to get the source instance ID
        source_instance = None
        with get_session() as db:
            from homecast.models.db.models import TopicSlot
            slot_record = db.get(TopicSlot, source_slot)
            if slot_record:
                source_instance = slot_record.instance_id

        routing_metadata = {
            "sourceInstance": source_instance or source_slot,  # Instance where web client is
            "sourceSlot": source_slot,
            "targetInstance": _get_instance_id(),  # Instance where Mac app is (this one)
            "routedViaPubsub": True,
            "directConnection": False
        }

        try:
            if self._local_handler:
                logger.info(f"[{correlation_id[:8]}] Calling local_handler for device {device_id[:8]}, action={action}")
                result = await self._local_handler(device_id, action, payload, 30.0, routing_metadata)
                logger.info(f"[{correlation_id[:8]}] local_handler succeeded for {action}")
                response = {"type": "response", "correlation_id": correlation_id, "payload": result}
            else:
                logger.error(f"[{correlation_id[:8]}] No local handler configured!")
                response = {
                    "type": "response",
                    "correlation_id": correlation_id,
                    "error": {"code": "NO_HANDLER", "message": "No local handler"}
                }
        except Exception as e:
            logger.error(f"[{correlation_id[:8]}] local_handler failed for {action}: {type(e).__name__}: {e}")
            response = {
                "type": "response",
                "correlation_id": correlation_id,
                "error": {"code": "ERROR", "message": str(e)}
            }

        # Send response back to source slot's topic
        source_topic = self._get_topic_path(source_slot)
        message_data = json.dumps(response).encode("utf-8")
        has_error = "error" in response

        logger.info(f"Sending response {correlation_id[:8]} to {source_topic} (error={has_error})")

        try:
            self._publisher.publish(source_topic, message_data).result(timeout=5)
            logger.info(f"Published response {correlation_id[:8]} to slot {source_slot}")
        except NotFound:
            logger.warning(f"Topic not found for slot {source_slot} - cleaning up")
            self._handle_deleted_topic(source_slot)
        except Exception as e:
            logger.error(f"Failed to publish response to slot {source_slot}: {e}")

    async def _handle_characteristic_update(self, data: Dict[str, Any]):
        """Handle a characteristic update broadcast from another instance."""
        from homecast.websocket.web_clients import web_client_manager

        user_id_str = data.get("user_id")
        accessory_id = data.get("accessory_id")
        characteristic_type = data.get("characteristic_type")
        value = data.get("value")

        if not all([user_id_str, accessory_id, characteristic_type]):
            logger.warning("Invalid characteristic_update message - missing fields")
            return

        user_id = uuid.UUID(user_id_str)
        logger.info(f"Received remote characteristic update for user {user_id}: {accessory_id[:8]}.../{characteristic_type}")

        # Broadcast to local web clients for this user
        await web_client_manager.broadcast_characteristic_update(
            user_id=user_id,
            accessory_id=accessory_id,
            characteristic_type=characteristic_type,
            value=value
        )

    async def _handle_reachability_update(self, data: Dict[str, Any]):
        """Handle a reachability update broadcast from another instance."""
        from homecast.websocket.web_clients import web_client_manager

        user_id_str = data.get("user_id")
        accessory_id = data.get("accessory_id")
        is_reachable = data.get("is_reachable")

        if not all([user_id_str, accessory_id]) or is_reachable is None:
            logger.warning("Invalid reachability_update message - missing fields")
            return

        user_id = uuid.UUID(user_id_str)
        logger.info(f"Received remote reachability update for user {user_id}: {accessory_id[:8]}... -> {'reachable' if is_reachable else 'unreachable'}")

        # Broadcast to local web clients for this user
        await web_client_manager.broadcast_reachability_update(
            user_id=user_id,
            accessory_id=accessory_id,
            is_reachable=is_reachable
        )

    async def _handle_batch_update(self, data: Dict[str, Any]):
        """Handle a batch of updates broadcast from another instance."""
        from homecast.websocket.web_clients import web_client_manager

        user_id_str = data.get("user_id")
        updates = data.get("updates", [])

        if not user_id_str or not updates:
            logger.warning("Invalid batch message - missing fields")
            return

        user_id = uuid.UUID(user_id_str)
        logger.info(f"Received batch of {len(updates)} updates for user {user_id}")

        # Process each update in the batch
        for update in updates:
            update_type = update.get("type")

            if update_type == "characteristic_update":
                accessory_id = update.get("accessory_id")
                characteristic_type = update.get("characteristic_type")
                value = update.get("value")

                if accessory_id and characteristic_type:
                    await web_client_manager.broadcast_characteristic_update(
                        user_id=user_id,
                        accessory_id=accessory_id,
                        characteristic_type=characteristic_type,
                        value=value
                    )

            elif update_type == "reachability_update":
                accessory_id = update.get("accessory_id")
                is_reachable = update.get("is_reachable")

                if accessory_id is not None and is_reachable is not None:
                    await web_client_manager.broadcast_reachability_update(
                        user_id=user_id,
                        accessory_id=accessory_id,
                        is_reachable=is_reachable
                    )

            else:
                logger.warning(f"Unknown update type in batch: {update_type}")

    async def _handle_remote_ping_request(self, data: Dict[str, Any]):
        """Handle a ping request routed from another instance."""
        from homecast.websocket.handler import connection_manager

        correlation_id = data.get("correlation_id")
        source_slot = data.get("source_slot")
        device_id = data.get("device_id")

        if not all([correlation_id, source_slot, device_id]):
            logger.warning("Invalid ping_request message - missing fields")
            return

        logger.info(f"Handling remote ping request {correlation_id[:8]}: device={device_id[:8]}, reply_to={source_slot}")

        # Check if device is actually connected to this instance
        is_local = connection_manager.is_connected(device_id)

        if not is_local:
            logger.warning(f"[{correlation_id[:8]}] Device {device_id[:8]} not connected to this instance for ping")
            response = {
                "type": "response",
                "correlation_id": correlation_id,
                "success": False,
                "error": "Device not connected to this instance"
            }
        else:
            # Ping the device locally
            ping_result = await connection_manager.ping_device(device_id, timeout=10.0)
            response = {
                "type": "response",
                "correlation_id": correlation_id,
                "success": ping_result.get("success", False),
                "latency_ms": ping_result.get("latency_ms"),
                "error": ping_result.get("error")
            }

        # Send response back to source slot's topic
        source_topic = self._get_topic_path(source_slot)
        message_data = json.dumps(response).encode("utf-8")

        try:
            self._publisher.publish(source_topic, message_data).result(timeout=5)
            logger.info(f"Sent ping response {correlation_id[:8]} to slot {source_slot}: success={response.get('success')}")
        except NotFound:
            logger.warning(f"Topic not found for slot {source_slot} - cleaning up")
            self._handle_deleted_topic(source_slot)
        except Exception as e:
            logger.error(f"Failed to publish ping response to slot {source_slot}: {e}")


# Global router instance
router = PubSubRouter()
