"""
System logger for persistent logging to database.

Provides structured logging that persists to the SystemLog table
for viewing in the admin panel.
"""

import logging
import json
import uuid
import asyncio
from typing import Optional, Dict, Any
from datetime import datetime, timezone
from functools import wraps

logger = logging.getLogger(__name__)


class SystemLogger:
    """
    Persistent logging to database for admin panel.

    Usage:
        SystemLogger.info("api", "User logged in", user_id=user.id)
        SystemLogger.error("websocket", "Connection failed", device_id=device_id, error=str(e))

    For tracing (correlating logs across systems):
        SystemLogger.info("api", "Request received", trace_id=trace_id, span_name="server_received")
    """

    @staticmethod
    def _write_log(
        level: str,
        source: str,
        message: str,
        user_id: Optional[uuid.UUID] = None,
        device_id: Optional[str] = None,
        trace_id: Optional[str] = None,
        span_name: Optional[str] = None,
        action: Optional[str] = None,
        accessory_id: Optional[str] = None,
        accessory_name: Optional[str] = None,
        characteristic_type: Optional[str] = None,
        value: Optional[str] = None,
        success: Optional[bool] = None,
        error: Optional[str] = None,
        latency_ms: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None
    ):
        """Internal method to write log entry to database."""
        try:
            from homecast.models.db.database import get_session
            from homecast.models.db.repositories import AdminRepository

            with get_session() as session:
                AdminRepository.create_log(
                    session=session,
                    level=level,
                    source=source,
                    message=message,
                    user_id=user_id,
                    device_id=device_id,
                    trace_id=trace_id,
                    span_name=span_name,
                    action=action,
                    accessory_id=accessory_id,
                    accessory_name=accessory_name,
                    characteristic_type=characteristic_type,
                    value=value,
                    success=success,
                    error=error,
                    latency_ms=latency_ms,
                    metadata=metadata,
                )
        except Exception as e:
            # Don't let logging errors crash the application
            logger.warning(f"Failed to write system log: {e}")

    @staticmethod
    def log(
        level: str,
        source: str,
        message: str,
        user_id: Optional[uuid.UUID] = None,
        device_id: Optional[str] = None,
        trace_id: Optional[str] = None,
        span_name: Optional[str] = None,
        action: Optional[str] = None,
        accessory_id: Optional[str] = None,
        accessory_name: Optional[str] = None,
        characteristic_type: Optional[str] = None,
        value: Optional[str] = None,
        success: Optional[bool] = None,
        error: Optional[str] = None,
        latency_ms: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None
    ):
        """
        Write a log entry to the database.

        Args:
            level: Log level (debug, info, warning, error)
            source: Log source (api, websocket, pubsub, relay, homekit, auth)
            message: Log message
            user_id: Optional user ID
            device_id: Optional device ID
            trace_id: Optional trace ID for distributed tracing
            span_name: Optional span name (client, server, pubsub, relay, homekit)
            action: Optional action name (set_characteristic, execute_scene)
            accessory_id: Optional accessory ID
            accessory_name: Optional accessory name
            characteristic_type: Optional characteristic type
            value: Optional value (as string)
            success: Optional success flag
            error: Optional error message
            latency_ms: Optional latency in milliseconds
            metadata: Optional additional metadata dict
        """
        SystemLogger._write_log(
            level=level,
            source=source,
            message=message,
            user_id=user_id,
            device_id=device_id,
            trace_id=trace_id,
            span_name=span_name,
            action=action,
            accessory_id=accessory_id,
            accessory_name=accessory_name,
            characteristic_type=characteristic_type,
            value=value,
            success=success,
            error=error,
            latency_ms=latency_ms,
            metadata=metadata,
        )

    @staticmethod
    def debug(source: str, message: str, **kwargs):
        """Write a debug log entry."""
        SystemLogger.log("debug", source, message, **kwargs)

    @staticmethod
    def info(source: str, message: str, **kwargs):
        """Write an info log entry."""
        SystemLogger.log("info", source, message, **kwargs)

    @staticmethod
    def warning(source: str, message: str, **kwargs):
        """Write a warning log entry."""
        SystemLogger.log("warning", source, message, **kwargs)

    @staticmethod
    def error(source: str, message: str, **kwargs):
        """Write an error log entry."""
        SystemLogger.log("error", source, message, **kwargs)


def generate_trace_id() -> str:
    """
    Generate a unique trace ID.

    Format: {timestamp_ms}-{random_8_chars}
    Example: 1705500000000-a1b2c3d4
    """
    timestamp_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    random_suffix = uuid.uuid4().hex[:8]
    return f"{timestamp_ms}-{random_suffix}"


def get_trace_context_from_request() -> Optional[Dict[str, str]]:
    """
    Extract trace context from the current request headers.

    Returns dict with trace_id, client_type, etc. if present.
    """
    try:
        from homecast.middleware import get_request
        request = get_request()
        if not request:
            return None

        trace_id = request.headers.get('X-Trace-ID')
        if not trace_id:
            return None

        return {
            'trace_id': trace_id,
            'client_type': request.headers.get('X-Client-Type', 'unknown'),
            'client_timestamp': request.headers.get('X-Client-Timestamp'),
        }
    except Exception:
        return None
