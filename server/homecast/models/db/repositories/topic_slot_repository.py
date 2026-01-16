"""
Repository for TopicSlot database operations.
"""

import secrets
import string
import logging
from datetime import datetime, timezone, timedelta
from typing import Optional

from sqlmodel import Session, select

from homecast.models.db.models import TopicSlot

logger = logging.getLogger(__name__)

# Slots are considered stale after this duration (instance died without releasing)
SLOT_TIMEOUT = timedelta(minutes=5)


def _generate_slot_name() -> str:
    """Generate a random 4-character alphanumeric slot name."""
    alphabet = string.ascii_lowercase + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(4))


class TopicSlotRepository:
    """Repository for topic slot operations."""

    @classmethod
    def claim_slot(
        cls,
        session: Session,
        instance_id: str
    ) -> TopicSlot:
        """
        Claim an available topic slot or create a new one.

        1. First, try to reclaim a slot this instance already owns
        2. Then, try to claim a stale slot (instance died)
        3. Finally, create a new slot

        Returns the claimed TopicSlot.
        """
        now = datetime.now(timezone.utc)
        stale_threshold = now - SLOT_TIMEOUT

        # 1. Check if we already have a slot (restart scenario)
        statement = select(TopicSlot).where(TopicSlot.instance_id == instance_id)
        existing = session.exec(statement).first()
        if existing:
            existing.claimed_at = now
            existing.last_heartbeat = now
            session.add(existing)
            session.commit()
            session.refresh(existing)
            logger.info(f"Reclaimed existing slot: {existing.slot_name}")
            return existing

        # 2. Try to claim a stale slot (previous instance died)
        statement = select(TopicSlot).where(
            (TopicSlot.instance_id == None) |  # noqa: E711
            (TopicSlot.last_heartbeat < stale_threshold)
        ).limit(1)
        stale = session.exec(statement).first()

        if stale:
            stale.instance_id = instance_id
            stale.claimed_at = now
            stale.last_heartbeat = now
            session.add(stale)
            session.commit()
            session.refresh(stale)
            logger.info(f"Claimed stale slot: {stale.slot_name}")
            return stale

        # 3. Create a new slot
        slot_name = _generate_slot_name()

        # Ensure uniqueness (very unlikely collision but handle it)
        while session.get(TopicSlot, slot_name):
            slot_name = _generate_slot_name()

        new_slot = TopicSlot(
            slot_name=slot_name,
            instance_id=instance_id,
            claimed_at=now,
            last_heartbeat=now
        )
        session.add(new_slot)
        session.commit()
        session.refresh(new_slot)
        logger.info(f"Created new slot: {new_slot.slot_name}")
        return new_slot

    @classmethod
    def release_slot(
        cls,
        session: Session,
        instance_id: str
    ) -> bool:
        """Release a slot when instance shuts down."""
        statement = select(TopicSlot).where(TopicSlot.instance_id == instance_id)
        slot = session.exec(statement).first()

        if slot:
            slot.instance_id = None
            slot.last_heartbeat = None
            session.add(slot)
            session.commit()
            logger.info(f"Released slot: {slot.slot_name}")
            return True

        return False

    @classmethod
    def heartbeat(
        cls,
        session: Session,
        instance_id: str
    ) -> bool:
        """Update heartbeat timestamp for a slot."""
        statement = select(TopicSlot).where(TopicSlot.instance_id == instance_id)
        slot = session.exec(statement).first()

        if slot:
            slot.last_heartbeat = datetime.now(timezone.utc)
            session.add(slot)
            session.commit()
            return True

        return False

    @classmethod
    def get_slot_for_instance(
        cls,
        session: Session,
        instance_id: str
    ) -> Optional[TopicSlot]:
        """Get the slot claimed by an instance."""
        statement = select(TopicSlot).where(TopicSlot.instance_id == instance_id)
        return session.exec(statement).first()

    @classmethod
    def get_all_active_slots(
        cls,
        session: Session
    ) -> list[TopicSlot]:
        """Get all currently active (claimed) slots."""
        now = datetime.now(timezone.utc)
        stale_threshold = now - SLOT_TIMEOUT

        statement = select(TopicSlot).where(
            TopicSlot.instance_id != None,  # noqa: E711
            TopicSlot.last_heartbeat >= stale_threshold
        )
        return list(session.exec(statement).all())

    @classmethod
    def delete_slot_by_name(cls, session: Session, slot_name: str) -> bool:
        """Delete a topic slot when its Pub/Sub topic has been deleted."""
        slot = session.get(TopicSlot, slot_name)
        if slot:
            session.delete(slot)
            session.commit()
            logger.info(f"Deleted stale slot: {slot_name}")
            return True
        return False

    @classmethod
    def get_all_slot_names(cls, session: Session) -> set[str]:
        """Get all slot names currently in the database."""
        statement = select(TopicSlot.slot_name)
        return set(session.exec(statement).all())

    @classmethod
    def claim_or_create_slot(cls, session: Session, instance_id: str, slot_name: str) -> TopicSlot:
        """Claim a specific slot by name, creating the DB record if needed."""
        now = datetime.now(timezone.utc)

        existing = session.get(TopicSlot, slot_name)
        if existing:
            existing.instance_id = instance_id
            existing.claimed_at = now
            existing.last_heartbeat = now
            session.add(existing)
            session.commit()
            session.refresh(existing)
            return existing

        new_slot = TopicSlot(
            slot_name=slot_name,
            instance_id=instance_id,
            claimed_at=now,
            last_heartbeat=now
        )
        session.add(new_slot)
        session.commit()
        session.refresh(new_slot)
        logger.info(f"Created slot record for orphaned topic: {slot_name}")
        return new_slot
