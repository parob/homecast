"""
Repository for Collection database operations.

Note: Collection sharing is now handled by EntityAccess via EntityAccessRepository.
Ownership is tracked via EntityAccess with access_type='user' and role='owner'.
"""

import logging
from typing import Optional, Tuple, List
from uuid import UUID

from sqlmodel import Session, select

from homecast.models.db.models import Collection, EntityAccess
from homecast.models.db.repositories.base_repository import BaseRepository

logger = logging.getLogger(__name__)


# Helper class to represent ownership access (compatible with old API)
class OwnerAccess:
    """Represents owner access to a collection."""
    def __init__(self, user_id: UUID, role: str = "owner"):
        self.user_id = user_id
        self.role = role


class CollectionRepository(BaseRepository):
    """Repository for collection operations."""

    MODEL_CLASS = Collection

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

        # Create owner access via EntityAccess (internal tracking)
        # Note: This is just to track who owns the collection, not for sharing
        # When the user wants to share, they'll use the ShareDialog which
        # creates proper EntityAccess records via EntityAccessRepository
        access = EntityAccess(
            entity_type="collection",
            entity_id=collection.id,
            owner_id=user_id,
            access_type="user",
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
    ) -> List[Tuple[Collection, OwnerAccess]]:
        """
        Get all collections a user owns.

        Returns:
            List of (collection, access) tuples
        """
        statement = (
            select(Collection, EntityAccess)
            .join(EntityAccess, Collection.id == EntityAccess.entity_id)
            .where(EntityAccess.entity_type == "collection")
            .where(EntityAccess.user_id == user_id)
            .where(EntityAccess.role == "owner")
            .order_by(Collection.created_at.desc())
        )
        results = session.exec(statement).all()
        # Convert to OwnerAccess for API compatibility
        return [(c, OwnerAccess(e.user_id, e.role)) for c, e in results]

    @classmethod
    def get_collection_with_access(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID
    ) -> Optional[Tuple[Collection, OwnerAccess]]:
        """
        Get a collection with the user's access record.

        Returns:
            Tuple of (collection, access) or None if not found/no access
        """
        statement = (
            select(Collection, EntityAccess)
            .join(EntityAccess, Collection.id == EntityAccess.entity_id)
            .where(Collection.id == collection_id)
            .where(EntityAccess.entity_type == "collection")
            .where(EntityAccess.user_id == user_id)
        )
        result = session.exec(statement).one_or_none()
        if not result:
            return None
        collection, entity_access = result
        return (collection, OwnerAccess(entity_access.user_id, entity_access.role))

    @classmethod
    def update_collection(
        cls,
        session: Session,
        collection_id: UUID,
        user_id: UUID,
        name: Optional[str] = None,
        payload: Optional[str] = None,
        settings_json: Optional[str] = None
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
        if settings_json is not None:
            collection.settings_json = settings_json

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

        # Delete all EntityAccess records for this collection first
        access_records = session.exec(
            select(EntityAccess)
            .where(EntityAccess.entity_type == "collection")
            .where(EntityAccess.entity_id == collection_id)
        ).all()
        for record in access_records:
            session.delete(record)

        # Flush to ensure access records are deleted before collection
        session.flush()

        # Delete collection
        session.delete(collection)
        session.commit()
        return True

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
            select(EntityAccess)
            .where(EntityAccess.entity_type == "collection")
            .where(EntityAccess.entity_id == collection_id)
            .where(EntityAccess.role == "owner")
        )
        access = session.exec(statement).first()
        return access.user_id if access else None
