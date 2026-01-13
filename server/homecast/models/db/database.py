from __future__ import annotations

import asyncio
import logging
from contextlib import contextmanager, asynccontextmanager
from typing import AsyncGenerator

from sqlalchemy import Engine, inspect, text
from sqlmodel import SQLModel, Session, create_engine

from homecast import config

logger = logging.getLogger(__name__)

# Global variable to hold the engine instance
_engine = None


def get_engine() -> Engine:
    """Lazily creates and returns the database engine."""
    global _engine
    if _engine is None:
        db_url = config.DATABASE_URL
        if not isinstance(db_url, str):
            raise ValueError(
                f"DATABASE_URL must be a string for the database engine. "
                f"Received type: {type(db_url)}. Please check your configuration."
            )
        if db_url.startswith("sqlite"):
            _engine = create_engine(
                db_url,
                echo=False,
                connect_args={"check_same_thread": False}
            )
        else:
            # PostgreSQL connection pooling optimizations
            _engine = create_engine(
                db_url,
                echo=False,
                pool_size=2,
                max_overflow=3,
                pool_pre_ping=True,
                pool_recycle=180,
                pool_timeout=20,
                connect_args={
                    "connect_timeout": 10,
                    "application_name": "homecast",
                    "options": "-c statement_timeout=30000",
                    "keepalives": 1,
                    "keepalives_idle": 30,
                    "keepalives_interval": 10,
                    "keepalives_count": 5
                }
            )
    return _engine


def create_db_and_tables():
    """Creates all database tables."""
    engine = get_engine()
    # Import models to register them with SQLModel.metadata
    from homecast.models.db import models  # noqa: F401
    SQLModel.metadata.create_all(engine)


@contextmanager
def get_session():
    """Provides a database session."""
    engine = get_engine()
    with Session(engine) as session:
        yield session


@asynccontextmanager
async def get_session_async() -> AsyncGenerator[Session, None]:
    """Provides an async-compatible database session."""
    def _create_session() -> Session:
        engine = get_engine()
        return Session(engine)

    session = await asyncio.to_thread(_create_session)
    try:
        yield session
    finally:
        await asyncio.to_thread(session.close)


def reset_engine():
    """Resets the global engine instance."""
    global _engine
    _engine = None


def validate_schema() -> bool:
    """Validate that the database schema matches SQLModel definitions."""
    from homecast.models.db import models as _  # noqa: F401

    try:
        engine = get_engine()
        inspector = inspect(engine)

        existing_tables = set(inspector.get_table_names())
        expected_tables = set(SQLModel.metadata.tables.keys())

        if not existing_tables:
            logger.info("Database is empty - first run scenario, validation passed")
            return True

        if existing_tables != expected_tables:
            missing_tables = expected_tables - existing_tables
            extra_tables = existing_tables - expected_tables
            if missing_tables:
                logger.warning("Missing tables in database: %s", missing_tables)
            if extra_tables:
                logger.warning("Extra tables in database: %s", extra_tables)
            return False

        for table_name in expected_tables:
            existing_columns = {col["name"] for col in inspector.get_columns(table_name)}
            expected_table = SQLModel.metadata.tables[table_name]
            expected_columns = set(expected_table.columns.keys())

            if existing_columns != expected_columns:
                missing_cols = expected_columns - existing_columns
                extra_cols = existing_columns - expected_columns
                if missing_cols:
                    logger.warning("Table %s missing columns: %s", table_name, missing_cols)
                if extra_cols:
                    logger.warning("Table %s has extra columns: %s", table_name, extra_cols)
                return False

        logger.info("Database schema validation passed")
        return True

    except Exception as exc:
        logger.error("Schema validation failed with error: %s", exc, exc_info=True)
        return False


def wipe_and_recreate_db() -> None:
    """Drop all tables and recreate the database schema.

    WARNING: This destroys all data in the database.
    Uses inspector to find ALL tables (including ones not in metadata)
    and drops them with CASCADE to handle foreign key constraints.
    """
    from homecast.models.db import models as _  # noqa: F401

    engine = get_engine()
    inspector = inspect(engine)

    logger.warning("Wiping database - dropping all tables")

    existing_tables = inspector.get_table_names()
    logger.info(f"Found {len(existing_tables)} tables to drop: {existing_tables}")

    if existing_tables:
        db_url = str(engine.url)
        is_postgres = 'postgresql' in db_url or 'postgres' in db_url
        is_sqlite = 'sqlite' in db_url

        if is_postgres:
            logger.info("PostgreSQL detected - terminating active connections")
            try:
                db_name = engine.url.database
                with engine.begin() as conn:
                    terminate_sql = text("""
                        SELECT pg_terminate_backend(pid)
                        FROM pg_stat_activity
                        WHERE datname = :db_name
                        AND pid <> pg_backend_pid()
                    """)
                    result = conn.execute(terminate_sql, {"db_name": db_name})
                    result.close()
                    logger.info("Terminated active connections")
            except Exception as exc:
                logger.warning(f"Could not terminate connections: {exc}")

        with engine.begin() as conn:
            if is_sqlite:
                conn.execute(text("PRAGMA foreign_keys = OFF"))

            for table_name in existing_tables:
                try:
                    logger.info(f"Dropping table: {table_name}")
                    quoted_table_name = f'"{table_name}"'

                    if is_sqlite:
                        drop_sql = f"DROP TABLE IF EXISTS {quoted_table_name}"
                    else:
                        drop_sql = f"DROP TABLE IF EXISTS {quoted_table_name} CASCADE"

                    result = conn.execute(text(drop_sql))
                    result.close()
                    logger.info(f"Dropped table: {table_name}")
                except Exception as exc:
                    logger.error(f"Failed to drop table {table_name}: {exc}", exc_info=True)

            # PostgreSQL: Clean up orphaned composite types that match table names
            if is_postgres:
                try:
                    type_query = text("""
                        SELECT typname FROM pg_type t
                        JOIN pg_namespace n ON t.typnamespace = n.oid
                        WHERE n.nspname = 'public'
                        AND t.typtype = 'c'
                        AND NOT EXISTS (
                            SELECT 1 FROM pg_class c
                            WHERE c.relname = t.typname AND c.relkind = 'r'
                        )
                    """)
                    orphaned_types = conn.execute(type_query).fetchall()
                    for (type_name,) in orphaned_types:
                        try:
                            logger.info(f"Dropping orphaned type: {type_name}")
                            conn.execute(text(f'DROP TYPE IF EXISTS "{type_name}" CASCADE'))
                            logger.info(f"Dropped type: {type_name}")
                        except Exception as exc:
                            logger.warning(f"Could not drop type {type_name}: {exc}")
                except Exception as exc:
                    logger.warning(f"Could not clean up orphaned types: {exc}")

            if is_sqlite:
                conn.execute(text("PRAGMA foreign_keys = ON"))

    logger.info("All tables dropped, recreating database schema")

    try:
        engine.dispose()
    except Exception as e:
        logger.warning(f"Error disposing engine: {e}")
    reset_engine()

    create_db_and_tables()
    logger.info("Database schema recreated successfully")


__all__ = [
    "get_engine",
    "create_db_and_tables",
    "get_session",
    "get_session_async",
    "validate_schema",
    "wipe_and_recreate_db",
    "reset_engine",
]
