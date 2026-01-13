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
from concurrent.futures import Future as ThreadFuture
from typing import Any, Callable, Dict, Optional

from homecast import config
from homecast.models.db.database import get_session
from homecast.models.db.repositories import SessionRepository, TopicSlotRepository

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

    async def connect(self):
        """Connect to Pub/Sub and start listening for messages."""
        if not self._enabled:
            logger.info("GCP_PROJECT_ID not configured - running in local-only mode")
            return

        try:
            from google.cloud import pubsub_v1
            from google.api_core.exceptions import AlreadyExists
            from google.protobuf.duration_pb2 import Duration

            self._project_id = config.GCP_PROJECT_ID
            self._loop = asyncio.get_event_loop()

            # Claim a topic slot from the database
            with get_session() as session:
                slot = TopicSlotRepository.claim_slot(session, _get_instance_id())
                self._slot_name = slot.slot_name

            logger.info(f"Claimed topic slot: {self._slot_name} (instance: {_get_instance_id()})")

            # Initialize Pub/Sub publisher
            self._publisher = pubsub_v1.PublisherClient()
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
            logger.info(f"Received Pub/Sub message: type={msg_type}, correlation={correlation_id}")

            if self._loop and self._loop.is_running():
                asyncio.run_coroutine_threadsafe(self._handle_message(data), self._loop)

            message.ack()
        except Exception as e:
            logger.error(f"Error processing message: {e}")
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
        timeout: float = 30.0
    ) -> Dict[str, Any]:
        """
        Send a request to a device, routing via Pub/Sub if needed.
        """
        if not self._enabled:
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Check local connections first (fast path - avoids DB lookup)
        if self._local_device_checker and self._local_device_checker(device_id):
            logger.debug(f"Device {device_id} is local, bypassing Pub/Sub")
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Look up device session from database
        with get_session() as db:
            session_record = SessionRepository.get_device_session(db, device_id, include_stale=False)
            if not session_record:
                raise ValueError(f"Device {device_id} not connected")

            device_instance_id = session_record.instance_id

        if not device_instance_id:
            raise ValueError(f"Device {device_id} has no instance_id")

        # Double-check: if device is on this instance, handle locally
        if device_instance_id == _get_instance_id():
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Look up which slot the target instance has claimed
        with get_session() as session:
            target_slot_record = TopicSlotRepository.get_slot_for_instance(session, device_instance_id)
            if not target_slot_record:
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
            except Exception as e:
                raise ValueError(f"Failed to route to slot {target_slot}: {e}")

            # Wait for result using run_in_executor (ThreadFuture.result blocks)
            loop = asyncio.get_running_loop()
            try:
                result = await loop.run_in_executor(None, future.result, timeout)
            except Exception as e:
                if "timed out" in str(e).lower():
                    raise TimeoutError(f"Device {device_id} did not respond in time")
                raise

            if "error" in result:
                raise ValueError(result["error"].get("message", "Unknown error"))

            return result.get("payload", {})
        finally:
            self._pending_requests.pop(correlation_id, None)

    async def broadcast_characteristic_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        characteristic_type: str,
        value: Any
    ):
        """
        Broadcast a characteristic update to all instances with web clients for this user.

        Looks up which instances have web clients and sends directly to their topics.
        """
        if not self._enabled:
            # Local-only mode - web_client_manager handles it directly
            return

        # Get all instance_ids that have web clients for this user
        with get_session() as db:
            instance_ids = SessionRepository.get_web_client_instance_ids(db, user_id)

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
            logger.debug(f"No remote instances to broadcast to for user {user_id}")
            return

        # Send to each target instance's topic
        message_data = json.dumps({
            "type": "characteristic_update",
            "user_id": str(user_id),
            "accessory_id": accessory_id,
            "characteristic_type": characteristic_type,
            "value": value
        }).encode("utf-8")

        for slot_name in target_slots:
            try:
                target_topic = self._get_topic_path(slot_name)
                self._publisher.publish(target_topic, message_data).result(timeout=5)
                logger.debug(f"Broadcast characteristic update to slot {slot_name}")
            except Exception as e:
                logger.error(f"Failed to broadcast to slot {slot_name}: {e}")

    async def broadcast_reachability_update(
        self,
        user_id: uuid.UUID,
        accessory_id: str,
        is_reachable: bool
    ):
        """
        Broadcast a reachability update to all instances with web clients for this user.

        Looks up which instances have web clients and sends directly to their topics.
        """
        if not self._enabled:
            # Local-only mode - web_client_manager handles it directly
            return

        # Get all instance_ids that have web clients for this user
        with get_session() as db:
            instance_ids = SessionRepository.get_web_client_instance_ids(db, user_id)

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
            logger.debug(f"No remote instances to broadcast to for user {user_id}")
            return

        # Send to each target instance's topic
        message_data = json.dumps({
            "type": "reachability_update",
            "user_id": str(user_id),
            "accessory_id": accessory_id,
            "is_reachable": is_reachable
        }).encode("utf-8")

        for slot_name in target_slots:
            try:
                target_topic = self._get_topic_path(slot_name)
                self._publisher.publish(target_topic, message_data).result(timeout=5)
                logger.debug(f"Broadcast reachability update to slot {slot_name}")
            except Exception as e:
                logger.error(f"Failed to broadcast to slot {slot_name}: {e}")

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

        else:
            logger.warning(f"Unknown message type: {msg_type}")

    async def _handle_remote_request(self, data: Dict[str, Any]):
        """Handle a request routed from another instance."""
        correlation_id = data["correlation_id"]
        source_slot = data["source_slot"]
        device_id = data["device_id"]
        action = data["action"]
        payload = data.get("payload", {})

        logger.info(f"Handling remote request {correlation_id[:8]}: device={device_id}, action={action}, reply_to={source_slot}")

        try:
            if self._local_handler:
                result = await self._local_handler(device_id, action, payload, 30.0)
                response = {"type": "response", "correlation_id": correlation_id, "payload": result}
            else:
                response = {
                    "type": "response",
                    "correlation_id": correlation_id,
                    "error": {"code": "NO_HANDLER", "message": "No local handler"}
                }
        except Exception as e:
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


# Global router instance
router = PubSubRouter()
