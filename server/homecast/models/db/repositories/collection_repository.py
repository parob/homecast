"""
Repository for Collection database operations.
"""

import json
import logging
import hashlib
import secrets
from datetime import datetime, timezone
from typing import Optional, Tuple, List
from uuid import UUID

from sqlmodel import Session, select

from homecast.models.db.models import Collection, CollectionAccess
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


class CollectionRepository(BaseRepository):
    """Repository for collection operations."""

    MODEL_CLASS = Collection

    # --- Passcode Hashing (same pattern as UserRepository) ---

    @classmethod
    def _hash_passcode(cls, passcode: str) -> str:
        """Hash a passcode with a random salt."""
        salt = secrets.token_hex(16)
        hash_obj = hashlib.pbkdf2_hmac(
            'sha256',
            passcode.encode('utf-8'),
            salt.encode('utf-8'),
            100000
        )
        return f"{salt}${hash_obj.hex()}"

    @classmethod
    def _verify_passcode(cls, passcode: str, passcode_hash: str) -> bool:
        """Verify a passcode against its hash."""
        try:
            salt, stored_hash = passcode_hash.split('$')
            hash_obj = hashlib.pbkdf2_hmac(
                'sha256',
                passcode.encode('utf-8'),
                salt.encode('utf-8'),
                100000
            )
            return hash_obj.hex() == stored_hash
        except (ValueError, AttributeError):
            return False

    # --- Access Schedule Validation ---

    @classmethod
    def check_access_schedule(
        cls,
        access: CollectionAccess
    ) -> Tuple[bool, Optional[str]]:
        """
        Check if access is allowed based on the schedule.

        Returns:
            Tuple of (is_allowed, error_message)
        """
        if not access.access_schedule:
            return (True, None)

        try:
            schedule = json.loads(access.access_schedule)
        except json.JSONDecodeError:
            return (True, None)  # Invalid JSON = no restrictions

        now = datetime.now(timezone.utc)

        # Check expiration
        expires_at = schedule.get("expires_at")
        if expires_at:
            try:
                expiry = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                if now > expiry:
                    return (False, "Access has expired")
            except (ValueError, TypeError):
                pass

        # Check time windows
        time_windows = schedule.get("time_windows")
        if time_windows:
            tz_name = schedule.get("timezone", "UTC")
            try:
                import zoneinfo
                tz = zoneinfo.ZoneInfo(tz_name)
            except Exception:
                tz = timezone.utc

            local_now = now.astimezone(tz)
            current_day = local_now.strftime("%a").lower()
            current_time = local_now.strftime("%H:%M")

            in_window = False
            for window in time_windows:
                days = [d.lower() for d in window.get("days", [])]
                start = window.get("start", "00:00")
                end = window.get("end", "23:59")

                if current_day in days and start <= current_time <= end:
                    in_window = True
                    break

            if not in_window:
                return (False, "Access not available at this time")

        return (True, None)

    # --- Collection CRUD ---

    @classmethod
    def create_collection(
        cls,
        session: Session,
        name: str,
        user_id: UUID
    ) -> Collection:
        """
        Create a new collection with owner access.

        Args:
            session: Database session
            name: Collection name
            user_id: ID of the user creating the collection

        Returns:
            Created collection
        """
        # Create collection
        collection = Collection(name=name)
        session.add(collection)
        session.flush()  # Get the ID

        # Create owner access
        access = CollectionAccess(
            collection_id=collection.id,
            user_id=user_id,
            role="owner"
        )
        session.add(access)
        session.commit()
        session.refresh(collection)

        return collection

    @classmethod
    def get_user_collections(
        cls,
        session: Session,
        user_id: UUID
    ) -> List[Tuple[Collection, CollectionAccess]]:
        """
        Get all collections a user has access to.

        Returns:
            List of (collection, access) tuples
        """
        statement = (
            select(Collection, CollectionAccess)
            .join(CollectionAccess, Collection.id == CollectionAccess.collection_id)
            .where(CollectionAccess.user_id == user_id)
            .order_by(Collection.created_at.desc())
        )
        results = session.exec(statement).all()
        return list(results)

    @classmethod
    def get_collection_with_access(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID
    ) -> Optional[Tuple[Collection, CollectionAccess]]:
        """
        Get a collection with the user's access record.

        Returns:
            Tuple of (collection, access) or None if not found/no access
        """
        statement = (
            select(Collection, CollectionAccess)
            .join(CollectionAccess, Collection.id == CollectionAccess.collection_id)
            .where(Collection.id == collection_id)
            .where(CollectionAccess.user_id == user_id)
        )
        result = session.exec(statement).one_or_none()
        return result

    @classmethod
    def update_collection(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID,
        name: Optional[str] = None,
        payload: Optional[str] = None
    ) -> Optional[Collection]:
        """
        Update a collection (must be owner).

        Returns:
            Updated collection or None if not found/not owner
        """
        result = cls.get_collection_with_access(session, collection_id, user_id)
        if not result:
            return None

        collection, access = result
        if access.role != "owner":
            return None

        if name is not None:
            collection.name = name
        if payload is not None:
            collection.payload = payload

        session.add(collection)
        session.commit()
        session.refresh(collection)
        return collection

    @classmethod
    def delete_collection(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID
    ) -> bool:
        """
        Delete a collection (must be owner).

        Returns:
            True if deleted, False if not found/not owner
        """
        result = cls.get_collection_with_access(session, collection_id, user_id)
        if not result:
            return False

        collection, access = result
        if access.role != "owner":
            return False

        # Delete all access records first
        access_records = session.exec(
            select(CollectionAccess).where(CollectionAccess.collection_id == collection_id)
        ).all()
        for record in access_records:
            session.delete(record)

        # Delete collection
        session.delete(collection)
        session.commit()
        return True

    # --- Public Share Management ---

    @classmethod
    def get_public_shares(
        cls,
        session: Session,
        collection_id: UUID
    ) -> List[CollectionAccess]:
        """
        Get all public share configs for a collection.

        Returns:
            List of CollectionAccess records where user_id is null
        """
        statement = (
            select(CollectionAccess)
            .where(CollectionAccess.collection_id == collection_id)
            .where(CollectionAccess.user_id == None)
        )
        return list(session.exec(statement).all())

    @classmethod
    def create_public_share(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID,
        role: str = "view",
        passcode: Optional[str] = None,
        schedule: Optional[str] = None
    ) -> Optional[CollectionAccess]:
        """
        Create a public share config for a collection (must be owner).

        Args:
            collection_id: Collection to share
            user_id: User creating the share (must be owner)
            role: Access level ("view" or "control")
            passcode: Optional passcode for access
            schedule: Optional JSON schedule config

        Returns:
            Created CollectionAccess or None if not owner
        """
        # Verify user is owner
        result = cls.get_collection_with_access(session, collection_id, user_id)
        if not result:
            return None

        _, access = result
        if access.role != "owner":
            return None

        # Create public share
        share = CollectionAccess(
            collection_id=collection_id,
            user_id=None,  # Public share
            role=role,
            passcode_hash=cls._hash_passcode(passcode) if passcode else None,
            access_schedule=schedule
        )
        session.add(share)
        session.commit()
        session.refresh(share)
        return share

    @classmethod
    def remove_public_share(
        cls,
        session: Session,
        access_id: UUID,
        user_id: UUID
    ) -> bool:
        """
        Remove a public share config (must be owner of the collection).

        Returns:
            True if removed, False otherwise
        """
        access = session.get(CollectionAccess, access_id)
        if not access or access.user_id is not None:
            return False  # Not a public share

        # Verify user is owner of the collection
        owner_access = cls.get_collection_with_access(session, access.collection_id, user_id)
        if not owner_access or owner_access[1].role != "owner":
            return False

        session.delete(access)
        session.commit()
        return True

    @classmethod
    def remove_all_public_shares(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID
    ) -> bool:
        """
        Remove all public shares for a collection (must be owner).

        Returns:
            True if any were removed, False otherwise
        """
        # Verify user is owner
        result = cls.get_collection_with_access(session, collection_id, user_id)
        if not result or result[1].role != "owner":
            return False

        shares = cls.get_public_shares(session, collection_id)
        for share in shares:
            session.delete(share)
        session.commit()
        return len(shares) > 0

    # --- Public Access ---

    @classmethod
    def get_collection_for_public(
        cls,
        session: Session,
        collection_id: UUID
    ) -> Optional[Collection]:
        """
        Get a collection by ID (for public access check).

        Returns:
            Collection or None if not found
        """
        return session.get(Collection, collection_id)

    @classmethod
    def verify_public_access(
        cls,
        session: Session,
        collection_id: UUID,
        passcode: Optional[str] = None
    ) -> Optional[CollectionAccess]:
        """
        Verify public access to a collection.

        Args:
            collection_id: Collection to access
            passcode: Optional passcode provided by visitor

        Returns:
            CollectionAccess record if access granted, None otherwise
        """
        shares = cls.get_public_shares(session, collection_id)
        if not shares:
            return None

        # First try to find a share without passcode
        for share in shares:
            if not share.passcode_hash:
                # Check schedule
                allowed, _ = cls.check_access_schedule(share)
                if allowed:
                    return share

        # If passcode provided, try to match
        if passcode:
            for share in shares:
                if share.passcode_hash and cls._verify_passcode(passcode, share.passcode_hash):
                    # Check schedule
                    allowed, _ = cls.check_access_schedule(share)
                    if allowed:
                        return share

        return None

    @classmethod
    def get_public_access_info(
        cls,
        session: Session,
        collection_id: UUID
    ) -> Tuple[bool, bool, Optional[str]]:
        """
        Get public access info for a collection.

        Returns:
            Tuple of (has_public_share, requires_password, access_level_if_no_password)
        """
        shares = cls.get_public_shares(session, collection_id)
        if not shares:
            return (False, False, None)

        # Check if any share doesn't require password
        for share in shares:
            if not share.passcode_hash:
                allowed, _ = cls.check_access_schedule(share)
                if allowed:
                    return (True, False, share.role)

        # All shares require password
        return (True, True, None)

    # --- Save Collection to User ---

    @classmethod
    def save_collection_to_user(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID,
        role: str = "view"
    ) -> Optional[CollectionAccess]:
        """
        Save a shared collection to a user's account.

        Args:
            collection_id: Collection to save
            user_id: User saving the collection
            role: Access level to grant (default: view)

        Returns:
            Created CollectionAccess or None if collection not found
        """
        # Verify collection exists
        collection = session.get(Collection, collection_id)
        if not collection:
            return None

        # Check if user already has access
        existing = cls.get_collection_with_access(session, collection_id, user_id)
        if existing:
            return existing[1]  # Already has access

        # Create user access
        access = CollectionAccess(
            collection_id=collection_id,
            user_id=user_id,
            role=role
        )
        session.add(access)
        session.commit()
        session.refresh(access)
        return access

    # --- Helper to get owner's user_id ---

    @classmethod
    def get_collection_owner_id(
        cls,
        session: Session,
        collection_id: UUID
    ) -> Optional[UUID]:
        """
        Get the owner's user_id for a collection.

        Returns:
            Owner's user_id or None if not found
        """
        statement = (
            select(CollectionAccess)
            .where(CollectionAccess.collection_id == collection_id)
            .where(CollectionAccess.role == "owner")
        )
        access = session.exec(statement).first()
        return access.user_id if access else None
