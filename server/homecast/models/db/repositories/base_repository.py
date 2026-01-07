"""
Base repository class with common database operations.
"""

from typing import Optional, Type
from uuid import UUID
from sqlmodel import Session, SQLModel, select


class BaseRepository:
    """
    Base repository class providing common CRUD operations.

    Subclasses must define MODEL_CLASS as a class variable.
    """

    MODEL_CLASS: Optional[Type[SQLModel]] = None

    @classmethod
    def find_by_id(
        cls,
        session: Session,
        id: UUID
    ) -> Optional[SQLModel]:
        """Find an entity by its ID."""
        assert cls.MODEL_CLASS is not None, "MODEL_CLASS must be defined"
        return session.get(cls.MODEL_CLASS, id)

    @classmethod
    def find_by_id_verified(
        cls,
        session: Session,
        id: UUID,
        error_message: str = "Entity not found"
    ) -> SQLModel:
        """Find an entity by ID and raise error if not found."""
        entity = cls.find_by_id(session, id)
        if not entity:
            raise ValueError(error_message)
        return entity

    @classmethod
    def create(
        cls,
        session: Session,
        entity: SQLModel,
        commit: bool = True,
        refresh: bool = True
    ) -> SQLModel:
        """Create a new entity."""
        session.add(entity)
        if commit:
            session.commit()
            if refresh:
                session.refresh(entity)
        else:
            session.flush()
        return entity

    @classmethod
    def update(
        cls,
        session: Session,
        entity: SQLModel,
        commit: bool = True,
        refresh: bool = True
    ) -> SQLModel:
        """Update an existing entity."""
        session.add(entity)
        if commit:
            session.commit()
            if refresh:
                session.refresh(entity)
        return entity

    @classmethod
    def delete(
        cls,
        session: Session,
        entity: SQLModel,
        commit: bool = True
    ) -> bool:
        """Delete an entity."""
        session.delete(entity)
        if commit:
            session.commit()
        return True

    @classmethod
    def exists(
        cls,
        session: Session,
        id: UUID
    ) -> bool:
        """Check if an entity exists by ID."""
        return cls.find_by_id(session, id) is not None

    @classmethod
    def find_all(
        cls,
        session: Session,
        limit: Optional[int] = None,
        offset: Optional[int] = None
    ) -> list[SQLModel]:
        """Find all entities with optional pagination."""
        assert cls.MODEL_CLASS is not None, "MODEL_CLASS must be defined"
        statement = select(cls.MODEL_CLASS)

        if offset is not None:
            statement = statement.offset(offset)
        if limit is not None:
            statement = statement.limit(limit)

        return list(session.exec(statement).all())
