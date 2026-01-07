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
from typing import Any, Callable, Dict, Optional

from homecast import config
from homecast.models.db.database import get_session
from homecast.models.db.repositories import DeviceRepository, TopicSlotRepository

logger = logging.getLogger(__name__)

# Cloud Run revision ID (for logging only)
REVISION_ID = os.getenv("K_REVISION", f"local-{str(uuid.uuid4())[:8]}")


class PubSubRouter:
    """
    Routes WebSocket messages between Cloud Run instances via Pub/Sub.

    Uses pooled topic slots from the database instead of per-revision topics.
    """

    def __init__(self):
        self._publisher = None
        self._subscriber = None
        self._subscription_future = None
        self._pending_requests: Dict[str, asyncio.Future] = {}
        self._local_handler: Optional[Callable] = None
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
        """Returns the slot_name which is used as instance_id in Device table."""
        return self._slot_name or REVISION_ID

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
                slot = TopicSlotRepository.claim_slot(session, REVISION_ID)
                self._slot_name = slot.slot_name

            logger.info(f"Claimed topic slot: {self._slot_name} (revision: {REVISION_ID})")

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

            logger.info(f"Pub/Sub router initialized, slot: {self._slot_name}")

        except Exception as e:
            logger.error(f"Failed to initialize Pub/Sub router: {e}", exc_info=True)
            self._enabled = False

    async def _heartbeat_loop(self):
        """Send periodic heartbeats to keep slot claimed."""
        try:
            while True:
                await asyncio.sleep(60)  # Every minute
                with get_session() as session:
                    TopicSlotRepository.heartbeat(session, REVISION_ID)
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
                TopicSlotRepository.release_slot(session, REVISION_ID)
            logger.info(f"Released slot: {self._slot_name}")

        logger.info("Pub/Sub router disconnected")

    def set_local_handler(self, handler: Callable):
        """Set the handler for requests to local devices."""
        self._local_handler = handler

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

        # Look up device location from database
        # Device.instance_id stores the slot_name
        with get_session() as session:
            device = DeviceRepository.find_by_device_id(session, device_id)
            if not device or device.status != "online":
                raise ValueError(f"Device {device_id} not connected")

            target_slot = device.instance_id

        if not target_slot:
            raise ValueError(f"Device {device_id} has no instance_id")

        # If device is on this slot, handle locally
        if target_slot == self._slot_name:
            if self._local_handler:
                return await self._local_handler(device_id, action, payload, timeout)
            raise ValueError("No local handler configured")

        # Route to remote instance via Pub/Sub
        correlation_id = str(uuid.uuid4())

        future: asyncio.Future = self._loop.create_future()
        self._pending_requests[correlation_id] = future

        logger.info(f"Routing request {correlation_id[:8]}: {self._slot_name} -> {target_slot} (device: {device_id}, action: {action})")

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

            result = await asyncio.wait_for(future, timeout=timeout)

            if "error" in result:
                raise ValueError(result["error"].get("message", "Unknown error"))

            return result.get("payload", {})

        except asyncio.TimeoutError:
            raise TimeoutError(f"Device {device_id} did not respond in time")
        finally:
            self._pending_requests.pop(correlation_id, None)

    async def _handle_message(self, data: Dict[str, Any]):
        """Handle an incoming Pub/Sub message."""
        msg_type = data.get("type")
        correlation_id = data.get("correlation_id")

        if msg_type == "response":
            logger.info(f"Processing response {correlation_id[:8] if correlation_id else 'none'}, pending={list(self._pending_requests.keys())[:3]}")
            if correlation_id and correlation_id in self._pending_requests:
                future = self._pending_requests[correlation_id]
                if not future.done():
                    future.set_result(data)
                    logger.info(f"Resolved Future for {correlation_id[:8]}")
                else:
                    logger.warning(f"Future already done for {correlation_id[:8]}")
            else:
                logger.warning(f"No pending request for correlation_id {correlation_id[:8] if correlation_id else 'none'}")

        elif msg_type == "request":
            await self._handle_remote_request(data)

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


# Global router instance
router = PubSubRouter()
