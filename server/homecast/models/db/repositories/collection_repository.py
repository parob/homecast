"""
Repository for Collection database operations.
"""

import json
import hashlib
import secrets
import logging
from datetime import datetime, timezone
from typing import Optional, List
from uuid import UUID

from sqlmodel import Session, select

from homecast.models.db.models import Collection, CollectionAccess, CollectionRole
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


class CollectionRepository(BaseRepository):
    """Repository for collection operations."""

    MODEL_CLASS = Collection

    # --- Collection CRUD ---

    @classmethod
    def create_collection(
        cls,
        session: Session,
        user_id: UUID,
        name: str
    ) -> Collection:
        """
        Create a new collection with the user as owner.

        Args:
            session: Database session
            user_id: ID of the user creating the collection
            name: Collection name

        Returns:
            Created collection
        """
        collection = Collection(name=name)
        cls.create(session, collection, commit=False)

        # Create owner access
        access = CollectionAccess(
            user_id=user_id,
            collection_id=collection.id,
            role=CollectionRole.OWNER.value
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
    ) -> List[tuple[Collection, str]]:
        """
        Get all collections the user has access to.

        Returns:
            List of (Collection, role) tuples
        """
        statement = (
            select(Collection, CollectionAccess.role)
            .join(CollectionAccess, Collection.id == CollectionAccess.collection_id)
            .where(CollectionAccess.user_id == user_id)
            .where(Collection.is_active == True)
        )
        results = session.exec(statement).all()
        return [(r[0], r[1]) for r in results]

    @classmethod
    def get_user_role(
        cls,
        session: Session,
        user_id: UUID,
        collection_id: UUID
    ) -> Optional[str]:
        """Get user's role for a collection, or None if no access."""
        statement = (
            select(CollectionAccess.role)
            .where(CollectionAccess.user_id == user_id)
            .where(CollectionAccess.collection_id == collection_id)
        )
        result = session.exec(statement).one_or_none()
        return result

    @classmethod
    def update_collection(
        cls,
        session: Session,
        collection_id: UUID,
        name: Optional[str] = None,
        items_json: Optional[str] = None
    ) -> Optional[Collection]:
        """Update a collection's name or items."""
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return None

        if name is not None:
            collection.name = name
        if items_json is not None:
            collection.items_json = items_json

        return cls.update(session, collection)

    @classmethod
    def delete_collection(
        cls,
        session: Session,
        collection_id: UUID
    ) -> bool:
        """Delete a collection and all its access records."""
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return False

        # Delete all access records
        statement = select(CollectionAccess).where(
            CollectionAccess.collection_id == collection_id
        )
        accesses = session.exec(statement).all()
        for access in accesses:
            session.delete(access)

        # Delete collection
        session.delete(collection)
        session.commit()
        return True

    # --- Access Management ---

    @classmethod
    def grant_access(
        cls,
        session: Session,
        user_id: UUID,
        collection_id: UUID,
        role: str
    ) -> CollectionAccess:
        """Grant a user access to a collection."""
        # Check if access already exists
        existing = cls.get_user_role(session, user_id, collection_id)
        if existing:
            # Update existing access
            statement = (
                select(CollectionAccess)
                .where(CollectionAccess.user_id == user_id)
                .where(CollectionAccess.collection_id == collection_id)
            )
            access = session.exec(statement).one()
            access.role = role
            session.add(access)
            session.commit()
            session.refresh(access)
            return access

        # Create new access
        access = CollectionAccess(
            user_id=user_id,
            collection_id=collection_id,
            role=role
        )
        session.add(access)
        session.commit()
        session.refresh(access)
        return access

    @classmethod
    def revoke_access(
        cls,
        session: Session,
        user_id: UUID,
        collection_id: UUID
    ) -> bool:
        """Revoke a user's access to a collection."""
        statement = (
            select(CollectionAccess)
            .where(CollectionAccess.user_id == user_id)
            .where(CollectionAccess.collection_id == collection_id)
        )
        access = session.exec(statement).one_or_none()
        if not access:
            return False

        session.delete(access)
        session.commit()
        return True

    # --- Sharing ---

    @classmethod
    def enable_sharing(
        cls,
        session: Session,
        collection_id: UUID,
        access_level: str,
        password: Optional[str] = None,
        expires_at: Optional[datetime] = None
    ) -> Optional[str]:
        """
        Enable sharing for a collection.

        Args:
            collection_id: Collection to share
            access_level: 'view' or 'control'
            password: Optional password for protection
            expires_at: Optional expiration datetime

        Returns:
            Share token, or None if collection not found
        """
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return None

        # Generate token if not already shared
        if not collection.share_token:
            collection.share_token = secrets.token_urlsafe(12)

        collection.is_shared = True
        collection.share_access_level = access_level
        collection.share_expires_at = expires_at

        if password:
            collection.share_password_hash = cls._hash_password(password)
        elif password == "":
            # Empty string means remove password
            collection.share_password_hash = None

        cls.update(session, collection)
        return collection.share_token

    @classmethod
    def disable_sharing(
        cls,
        session: Session,
        collection_id: UUID
    ) -> bool:
        """Disable sharing for a collection."""
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return False

        collection.is_shared = False
        # Keep token and settings in case they re-enable
        cls.update(session, collection)
        return True

    @classmethod
    def find_by_token(
        cls,
        session: Session,
        token: str
    ) -> Optional[Collection]:
        """Find a collection by its share token."""
        statement = select(Collection).where(Collection.share_token == token)
        return session.exec(statement).one_or_none()

    @classmethod
    def is_share_valid(cls, collection: Collection) -> bool:
        """Check if a collection's share is currently valid."""
        if not collection.is_shared:
            return False

        if not collection.is_active:
            return False

        if collection.share_expires_at:
            if datetime.now(timezone.utc) > collection.share_expires_at:
                return False

        return True

    @classmethod
    def verify_share_password(
        cls,
        password: str,
        password_hash: str
    ) -> bool:
        """Verify a password against its hash."""
        try:
            salt, stored_hash = password_hash.split('$')
            hash_obj = hashlib.pbkdf2_hmac(
                'sha256',
                password.encode('utf-8'),
                salt.encode('utf-8'),
                100000
            )
            return hash_obj.hex() == stored_hash
        except (ValueError, AttributeError):
            return False

    @classmethod
    def _hash_password(cls, password: str) -> str:
        """Hash a password with a random salt."""
        salt = secrets.token_hex(16)
        hash_obj = hashlib.pbkdf2_hmac(
            'sha256',
            password.encode('utf-8'),
            salt.encode('utf-8'),
            100000
        )
        return f"{salt}${hash_obj.hex()}"

    # --- Save Collection ---

    @classmethod
    def save_collection(
        cls,
        session: Session,
        user_id: UUID,
        collection_id: UUID
    ) -> Optional[CollectionAccess]:
        """
        Save a shared collection for a user (creates viewer access).

        Returns None if collection doesn't exist or user already has access.
        """
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return None

        # Check if user already has access
        existing_role = cls.get_user_role(session, user_id, collection_id)
        if existing_role:
            return None  # Already has access

        # Grant view access
        return cls.grant_access(session, user_id, collection_id, CollectionRole.VIEW.value)

    # --- Items ---

    @classmethod
    def get_items(cls, collection: Collection) -> List[dict]:
        """Parse and return collection items."""
        try:
            return json.loads(collection.items_json)
        except (json.JSONDecodeError, TypeError):
            return []

    @classmethod
    def set_items(
        cls,
        session: Session,
        collection_id: UUID,
        items: List[dict]
    ) -> Optional[Collection]:
        """Set collection items."""
        return cls.update_collection(
            session,
            collection_id,
            items_json=json.dumps(items)
        )

    @classmethod
    def add_item(
        cls,
        session: Session,
        collection_id: UUID,
        item: dict
    ) -> Optional[Collection]:
        """Add an item to a collection."""
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return None

        items = cls.get_items(collection)
        items.append(item)
        return cls.set_items(session, collection_id, items)

    @classmethod
    def remove_item(
        cls,
        session: Session,
        collection_id: UUID,
        item_index: int
    ) -> Optional[Collection]:
        """Remove an item from a collection by index."""
        collection = cls.find_by_id(session, collection_id)
        if not collection:
            return None

        items = cls.get_items(collection)
        if 0 <= item_index < len(items):
            items.pop(item_index)
            return cls.set_items(session, collection_id, items)
        return collection
