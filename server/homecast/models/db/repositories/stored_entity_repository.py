"""Repository for StoredEntity operations."""

from typing import Optional
from uuid import UUID
from datetime import datetime, timezone
from sqlmodel import Session, select

from ..models import StoredEntity


class StoredEntityRepository:
    """Repository for StoredEntity CRUD operations."""

    @staticmethod
    def get_entity(
        session: Session,
        owner_id: UUID,
        entity_type: str,
        entity_id: str
    ) -> StoredEntity | None:
        """Get a specific entity by owner, type, and ID."""
        stmt = select(StoredEntity).where(
            StoredEntity.owner_id == owner_id,
            StoredEntity.entity_type == entity_type,
            StoredEntity.entity_id == entity_id
        )
        return session.exec(stmt).first()

    @staticmethod
    def upsert_entity(
        session: Session,
        owner_id: UUID,
        entity_type: str,
        entity_id: str,
        data_json: str | None = None,
        layout_json: str | None = None,
        parent_id: str | None = None
    ) -> StoredEntity:
        """Create or update an entity."""
        entity = StoredEntityRepository.get_entity(session, owner_id, entity_type, entity_id)
        if entity:
            if data_json is not None:
                entity.data_json = data_json
            if layout_json is not None:
                entity.layout_json = layout_json
            if parent_id is not None:
                entity.parent_id = parent_id
            entity.updated_at = datetime.now(timezone.utc)
        else:
            entity = StoredEntity(
                owner_id=owner_id,
                entity_type=entity_type,
                entity_id=entity_id,
                parent_id=parent_id,
                data_json=data_json or "{}",
                layout_json=layout_json or "{}"
            )
            session.add(entity)
        session.commit()
        session.refresh(entity)
        return entity

    @staticmethod
    def get_entities_by_type(
        session: Session,
        owner_id: UUID,
        entity_type: str
    ) -> list[StoredEntity]:
        """Get all entities of a type for an owner."""
        stmt = select(StoredEntity).where(
            StoredEntity.owner_id == owner_id,
            StoredEntity.entity_type == entity_type
        )
        return list(session.exec(stmt).all())

    @staticmethod
    def get_entities_by_parent(
        session: Session,
        owner_id: UUID,
        parent_id: str
    ) -> list[StoredEntity]:
        """Get all entities with a specific parent ID."""
        stmt = select(StoredEntity).where(
            StoredEntity.owner_id == owner_id,
            StoredEntity.parent_id == parent_id
        )
        return list(session.exec(stmt).all())

    @staticmethod
    def update_layout(
        session: Session,
        owner_id: UUID,
        entity_type: str,
        entity_id: str,
        layout_json: str
    ) -> StoredEntity | None:
        """Update just the layout for an entity."""
        entity = StoredEntityRepository.get_entity(session, owner_id, entity_type, entity_id)
        if entity:
            entity.layout_json = layout_json
            entity.updated_at = datetime.now(timezone.utc)
            session.commit()
            session.refresh(entity)
        return entity

    @staticmethod
    def bulk_upsert(
        session: Session,
        owner_id: UUID,
        entities: list[dict]
    ) -> list[StoredEntity]:
        """
        Bulk upsert entities. Preserves existing layouts.

        Each entity dict should have:
        - entity_type: str
        - entity_id: str
        - data_json: str (optional)
        - parent_id: str (optional)
        """
        results = []
        for e in entities:
            existing = StoredEntityRepository.get_entity(
                session, owner_id, e['entity_type'], e['entity_id']
            )
            if existing:
                # Update data but preserve layout
                existing.data_json = e.get('data_json', '{}')
                if 'parent_id' in e:
                    existing.parent_id = e['parent_id']
                existing.updated_at = datetime.now(timezone.utc)
                results.append(existing)
            else:
                entity = StoredEntity(
                    owner_id=owner_id,
                    entity_type=e['entity_type'],
                    entity_id=e['entity_id'],
                    parent_id=e.get('parent_id'),
                    data_json=e.get('data_json', '{}'),
                    layout_json='{}'  # New entities start with empty layout
                )
                session.add(entity)
                results.append(entity)
        session.commit()
        for r in results:
            session.refresh(r)
        return results

    @staticmethod
    def delete_entity(
        session: Session,
        owner_id: UUID,
        entity_type: str,
        entity_id: str
    ) -> bool:
        """Delete an entity and its children."""
        entity = StoredEntityRepository.get_entity(session, owner_id, entity_type, entity_id)
        if not entity:
            return False
        # Delete children first
        children = StoredEntityRepository.get_entities_by_parent(session, owner_id, entity_id)
        for child in children:
            session.delete(child)
        session.delete(entity)
        session.commit()
        return True

    @staticmethod
    def get_all_entities(
        session: Session,
        owner_id: UUID
    ) -> list[StoredEntity]:
        """Get all entities for an owner."""
        stmt = select(StoredEntity).where(
            StoredEntity.owner_id == owner_id
        )
        return list(session.exec(stmt).all())
