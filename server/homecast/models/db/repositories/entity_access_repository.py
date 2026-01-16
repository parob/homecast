"""
Repository for EntityAccess database operations.

Handles unified access control for all entity types:
collections, rooms, groups, homes, and accessories.
"""

import json
import logging
import hashlib
import secrets
from datetime import datetime, timezone
from typing import Optional, Tuple, List
from uuid import UUID

from sqlmodel import Session, select, or_, and_

from homecast.models.db.models import EntityAccess, Collection
from homecast.models.db.repositories.base_repository import BaseRepository
from homecast.utils.share_hash import encode_share_hash, decode_share_hash, verify_share_hash

logger = logging.getLogger(__name__)


# Valid entity types
VALID_ENTITY_TYPES = {"collection", "room", "group", "home", "accessory"}

# Valid access types
VALID_ACCESS_TYPES = {"public", "passcode", "user"}

# Valid roles
VALID_ROLES = {"view", "control"}


class EntityAccessRepository(BaseRepository):
    """Repository for entity access operations."""

    MODEL_CLASS = EntityAccess

    # --- Passcode Hashing ---

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
        access: EntityAccess
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
            return (True, None)

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

    # --- Entity Access CRUD ---

    @classmethod
    def get_entity_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> List[EntityAccess]:
        """
        Get all access configs for an entity.

        Args:
            session: Database session
            entity_type: Type of entity
            entity_id: Entity UUID

        Returns:
            List of EntityAccess records
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
            .order_by(EntityAccess.created_at)
        )
        return list(session.exec(statement).all())

    @classmethod
    def get_access_by_id(
        cls,
        session: Session,
        access_id: UUID
    ) -> Optional[EntityAccess]:
        """Get a single access record by ID."""
        return session.get(EntityAccess, access_id)

    @classmethod
    def create_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID,
        owner_id: UUID,
        access_type: str,
        role: str = "view",
        home_id: Optional[UUID] = None,
        user_id: Optional[UUID] = None,
        passcode: Optional[str] = None,
        name: Optional[str] = None,
        access_schedule: Optional[str] = None
    ) -> EntityAccess:
        """
        Create a new access config for an entity.

        Args:
            session: Database session
            entity_type: Type of entity (collection, room, group, home, accessory)
            entity_id: UUID of the entity
            owner_id: User who owns/created this share
            access_type: Type of access (public, passcode, user)
            role: Permission level (view, control)
            home_id: Required for room/group/accessory
            user_id: Required for access_type="user"
            passcode: Required for access_type="passcode"
            name: Optional label for passcode
            access_schedule: Optional JSON schedule config

        Returns:
            Created EntityAccess record

        Raises:
            ValueError: If invalid parameters
        """
        if entity_type not in VALID_ENTITY_TYPES:
            raise ValueError(f"Invalid entity type: {entity_type}")
        if access_type not in VALID_ACCESS_TYPES:
            raise ValueError(f"Invalid access type: {access_type}")
        if role not in VALID_ROLES:
            raise ValueError(f"Invalid role: {role}")

        # Validate access_type-specific requirements
        if access_type == "user" and not user_id:
            raise ValueError("user_id required for access_type='user'")
        if access_type == "passcode" and not passcode:
            raise ValueError("passcode required for access_type='passcode'")

        # For public access, check if one already exists
        if access_type == "public":
            existing = cls.get_public_access(session, entity_type, entity_id)
            if existing:
                raise ValueError("Public access already exists for this entity")

        access = EntityAccess(
            entity_type=entity_type,
            entity_id=entity_id,
            home_id=home_id,
            owner_id=owner_id,
            access_type=access_type,
            user_id=user_id if access_type == "user" else None,
            passcode_hash=cls._hash_passcode(passcode) if passcode else None,
            name=name,
            role=role,
            access_schedule=access_schedule
        )

        session.add(access)
        session.commit()
        session.refresh(access)
        return access

    @classmethod
    def update_access(
        cls,
        session: Session,
        access_id: UUID,
        owner_id: UUID,
        role: Optional[str] = None,
        passcode: Optional[str] = None,
        name: Optional[str] = None,
        access_schedule: Optional[str] = None
    ) -> Optional[EntityAccess]:
        """
        Update an access config (must be owner).

        Args:
            session: Database session
            access_id: Access record ID
            owner_id: Must match the owner_id of the access record
            role: New role (optional)
            passcode: New passcode (optional, only for passcode access)
            name: New name (optional)
            access_schedule: New schedule (optional)

        Returns:
            Updated EntityAccess or None if not found/not owner
        """
        access = session.get(EntityAccess, access_id)
        if not access or access.owner_id != owner_id:
            return None

        if role is not None:
            if role not in VALID_ROLES:
                raise ValueError(f"Invalid role: {role}")
            access.role = role

        if passcode is not None and access.access_type == "passcode":
            access.passcode_hash = cls._hash_passcode(passcode)

        if name is not None:
            access.name = name

        if access_schedule is not None:
            access.access_schedule = access_schedule

        session.add(access)
        session.commit()
        session.refresh(access)
        return access

    @classmethod
    def delete_access(
        cls,
        session: Session,
        access_id: UUID,
        owner_id: UUID
    ) -> bool:
        """
        Delete an access config (must be owner).

        Returns:
            True if deleted, False if not found/not owner
        """
        access = session.get(EntityAccess, access_id)
        if not access or access.owner_id != owner_id:
            return False

        session.delete(access)
        session.commit()
        return True

    @classmethod
    def delete_all_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID,
        owner_id: UUID
    ) -> int:
        """
        Delete all access configs for an entity (must be owner).

        Returns:
            Number of deleted records
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
            .where(EntityAccess.owner_id == owner_id)
        )
        records = list(session.exec(statement).all())

        for record in records:
            session.delete(record)

        session.commit()
        return len(records)

    # --- Public Access ---

    @classmethod
    def get_public_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> Optional[EntityAccess]:
        """
        Get the public access config for an entity (if any).

        Returns:
            EntityAccess with access_type="public" or None
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
            .where(EntityAccess.access_type == "public")
        )
        return session.exec(statement).first()

    @classmethod
    def get_passcode_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> List[EntityAccess]:
        """
        Get all passcode access configs for an entity.

        Returns:
            List of EntityAccess with access_type="passcode"
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
            .where(EntityAccess.access_type == "passcode")
        )
        return list(session.exec(statement).all())

    # --- Access Verification ---

    @classmethod
    def verify_access(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID,
        passcode: Optional[str] = None,
        user_id: Optional[UUID] = None
    ) -> Optional[EntityAccess]:
        """
        Verify access to an entity.

        Checks in order:
        1. User-specific access (if user_id provided)
        2. Public access (no passcode required)
        3. Passcode access (if passcode provided)

        Args:
            session: Database session
            entity_type: Type of entity
            entity_id: Entity UUID
            passcode: Optional passcode
            user_id: Optional authenticated user ID

        Returns:
            EntityAccess record granting access, or None if denied
        """
        # Get all access configs for this entity
        all_access = cls.get_entity_access(session, entity_type, entity_id)
        if not all_access:
            return None

        best_access = None

        # First check user-specific access
        if user_id:
            for access in all_access:
                if access.access_type == "user" and access.user_id == user_id:
                    allowed, _ = cls.check_access_schedule(access)
                    if allowed:
                        # User access takes priority
                        if not best_access or access.role == "control":
                            best_access = access

        # Check public access
        for access in all_access:
            if access.access_type == "public":
                allowed, _ = cls.check_access_schedule(access)
                if allowed:
                    if not best_access or access.role == "control":
                        best_access = access

        # Check passcode access (can upgrade permissions)
        if passcode:
            for access in all_access:
                if access.access_type == "passcode" and access.passcode_hash:
                    if cls._verify_passcode(passcode, access.passcode_hash):
                        allowed, _ = cls.check_access_schedule(access)
                        if allowed:
                            # Passcode can upgrade to control
                            if not best_access or access.role == "control":
                                best_access = access

        return best_access

    @classmethod
    def verify_access_by_hash(
        cls,
        session: Session,
        share_hash: str,
        passcode: Optional[str] = None,
        user_id: Optional[UUID] = None
    ) -> Tuple[Optional[EntityAccess], Optional[str], Optional[UUID]]:
        """
        Verify access using a share hash.

        Args:
            session: Database session
            share_hash: The hash from the share URL
            passcode: Optional passcode
            user_id: Optional authenticated user ID

        Returns:
            Tuple of (EntityAccess, entity_type, entity_id) or (None, None, None) if invalid
        """
        try:
            entity_type, id_prefix, signature = decode_share_hash(share_hash)
        except ValueError:
            return (None, None, None)

        # Find entity with matching ID prefix
        entity_id = cls._find_entity_by_prefix(session, entity_type, id_prefix)
        if not entity_id:
            return (None, None, None)

        # Verify the hash signature
        if not verify_share_hash(share_hash, entity_type, entity_id):
            return (None, None, None)

        # Verify access
        access = cls.verify_access(session, entity_type, entity_id, passcode, user_id)
        if not access:
            return (None, None, None)

        return (access, entity_type, entity_id)

    @classmethod
    def _find_entity_by_prefix(
        cls,
        session: Session,
        entity_type: str,
        id_prefix: str
    ) -> Optional[UUID]:
        """
        Find an entity by type and ID prefix.

        Args:
            session: Database session
            entity_type: Type of entity
            id_prefix: First 8 chars of UUID (no hyphens)

        Returns:
            Full entity UUID or None if not found
        """
        # For collections, we can query the Collection table
        if entity_type == "collection":
            # SQLite/PostgreSQL: cast UUID to string and use LIKE
            # For simplicity, we'll get all entity_access records with this type
            # and filter by prefix
            statement = (
                select(EntityAccess.entity_id)
                .where(EntityAccess.entity_type == entity_type)
                .distinct()
            )
            entity_ids = session.exec(statement).all()

            for eid in entity_ids:
                if str(eid).replace("-", "").startswith(id_prefix):
                    return eid

        # For other types (room, group, home, accessory), we look in entity_access
        # since we don't have separate tables for them
        statement = (
            select(EntityAccess.entity_id)
            .where(EntityAccess.entity_type == entity_type)
            .distinct()
        )
        entity_ids = session.exec(statement).all()

        for eid in entity_ids:
            if str(eid).replace("-", "").startswith(id_prefix):
                return eid

        return None

    # --- User Shared Entities ---

    @classmethod
    def get_user_shared_entities(
        cls,
        session: Session,
        user_id: UUID
    ) -> List[EntityAccess]:
        """
        Get all entities shared with a specific user.

        Args:
            session: Database session
            user_id: User to get shares for

        Returns:
            List of EntityAccess records where user has access_type="user"
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.access_type == "user")
            .where(EntityAccess.user_id == user_id)
            .order_by(EntityAccess.created_at.desc())
        )
        return list(session.exec(statement).all())

    @classmethod
    def get_entities_owned_by_user(
        cls,
        session: Session,
        user_id: UUID,
        entity_type: Optional[str] = None
    ) -> List[EntityAccess]:
        """
        Get all entities where user is the owner (has shared them).

        Args:
            session: Database session
            user_id: Owner user ID
            entity_type: Optional filter by type

        Returns:
            List of EntityAccess records
        """
        statement = select(EntityAccess).where(EntityAccess.owner_id == user_id)

        if entity_type:
            statement = statement.where(EntityAccess.entity_type == entity_type)

        return list(session.exec(statement).all())

    # --- Share Link Generation ---

    @classmethod
    def get_share_hash(
        cls,
        entity_type: str,
        entity_id: UUID
    ) -> str:
        """
        Generate a share hash for an entity.

        Args:
            entity_type: Type of entity
            entity_id: Entity UUID

        Returns:
            Share hash string
        """
        return encode_share_hash(entity_type, entity_id)

    # --- Helper to get entity owner ---

    @classmethod
    def get_entity_owner_id(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> Optional[UUID]:
        """
        Get the owner ID for an entity (from any access record).

        Returns:
            Owner's user_id or None if not found
        """
        statement = (
            select(EntityAccess.owner_id)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
        )
        result = session.exec(statement).first()
        return result

    # --- Check if entity is shared ---

    @classmethod
    def is_entity_shared(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> bool:
        """
        Check if an entity has any sharing configured.

        Returns:
            True if any access records exist
        """
        statement = (
            select(EntityAccess)
            .where(EntityAccess.entity_type == entity_type)
            .where(EntityAccess.entity_id == entity_id)
            .limit(1)
        )
        return session.exec(statement).first() is not None

    @classmethod
    def get_sharing_info(
        cls,
        session: Session,
        entity_type: str,
        entity_id: UUID
    ) -> dict:
        """
        Get summary of sharing configuration for an entity.

        Returns:
            Dict with:
            - is_shared: bool
            - has_public: bool
            - public_role: Optional[str]
            - passcode_count: int
            - user_count: int
            - share_hash: str
        """
        access_list = cls.get_entity_access(session, entity_type, entity_id)

        public_access = None
        passcode_count = 0
        user_count = 0

        for access in access_list:
            if access.access_type == "public":
                public_access = access
            elif access.access_type == "passcode":
                passcode_count += 1
            elif access.access_type == "user":
                user_count += 1

        return {
            "is_shared": len(access_list) > 0,
            "has_public": public_access is not None,
            "public_role": public_access.role if public_access else None,
            "passcode_count": passcode_count,
            "user_count": user_count,
            "share_hash": encode_share_hash(entity_type, entity_id)
        }
