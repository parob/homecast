"""
HomeCast Server Application.

Main entry point for the Cloud Run deployment.
"""

import asyncio
import logging
from contextlib import asynccontextmanager

from starlette.applications import Starlette
from starlette.routing import Route, Mount, WebSocketRoute
from starlette.responses import JSONResponse
from graphql_api import GraphQLAPI
from graphql_http import GraphQLHTTP

from homecast import config
from homecast.api.api import HomecastAPI
from homecast.middleware import (
    CORSMiddleware,
    RequestContextMiddleware,
)
from homecast.models.db.database import (
    create_db_and_tables,
    validate_schema,
    wipe_and_recreate_db,
    get_session,
)
from homecast.websocket.handler import (
    websocket_endpoint,
    ping_clients,
    init_pubsub_router,
    shutdown_pubsub_router,
)
from homecast.websocket.web_clients import (
    web_client_endpoint,
    cleanup_stale_sessions,
    cleanup_instance_sessions,
)
from homecast.home_app import home_scoped_app, home_http_app


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def create_app() -> Starlette:
    """Create and configure the Starlette application."""

    # Create GraphQL app
    graphql_app = GraphQLHTTP.from_api(
        api=GraphQLAPI(root_type=HomecastAPI),
        auth_enabled=False  # We handle auth in middleware
    ).app

    # Health check endpoint
    async def health(request):
        return JSONResponse({"status": "ok"})

    # Lifespan handler for startup/shutdown
    @asynccontextmanager
    async def lifespan(app: Starlette):
        # Initialize HomeAPI app lifespan (required for FastMCP task group)
        async with home_http_app.lifespan(app):
            logger.info("HomeCast server starting up...")

            # Database setup
            if getattr(config, "VALIDATE_OR_WIPE_DB_ON_STARTUP", False):
                if not validate_schema():
                    logger.warning("Database schema validation failed - wiping and recreating")
                    wipe_and_recreate_db()
                else:
                    from sqlalchemy import inspect
                    from homecast.models.db.database import get_engine
                    engine = get_engine()
                    inspector = inspect(engine)
                    if not inspector.get_table_names():
                        logger.info("Database is empty - creating tables")
                        create_db_and_tables()
            elif getattr(config, "CREATE_DB_ON_STARTUP", False):
                create_db_and_tables()

            # Seed default user if not exists
            import uuid
            from homecast.models.db.models import User
            from homecast.models.db.repositories import UserRepository
            with get_session() as session:
                if not UserRepository.find_by_email(session, "rob@parob.com"):
                    user = User(
                        id=uuid.UUID("c4e0cb24-e0ec-4831-906b-9a35d387aa2e"),
                        email="rob@parob.com",
                        password_hash=UserRepository._hash_password("robrobrob"),
                        name="Rob"
                    )
                    session.add(user)
                    session.commit()
                    logger.info("Seeded default user: rob@parob.com")

            # Initialize Pub/Sub router for cross-instance WebSocket routing
            await init_pubsub_router()

            # Start background tasks
            ping_task = asyncio.create_task(ping_clients())
            session_cleanup_task = asyncio.create_task(cleanup_stale_sessions())

            logger.info("HomeCast server ready")
            yield

            # Cleanup
            ping_task.cancel()
            session_cleanup_task.cancel()
            try:
                await ping_task
            except asyncio.CancelledError:
                pass
            try:
                await session_cleanup_task
            except asyncio.CancelledError:
                pass

            # Clean up all sessions for this instance
            await cleanup_instance_sessions()

            await shutdown_pubsub_router()
            logger.info("HomeCast server shutting down")

    # Create main app
    app = Starlette(
        routes=[
            Route('/health', endpoint=health, methods=['GET']),
            WebSocketRoute('/ws', endpoint=websocket_endpoint),  # Mac app WebSocket
            WebSocketRoute('/ws/web', endpoint=web_client_endpoint),  # Web UI WebSocket
            Mount('/home/', app=home_scoped_app, name='home'),  # Home-scoped API endpoints
            Mount('/', app=graphql_app, name='graphql'),
        ],
        lifespan=lifespan
    )

    # Add middleware (order matters - first added is outermost)
    app.add_middleware(
        CORSMiddleware,
        allowed_origins=config.ALLOWED_CORS_ORIGINS,
        allowed_origin_patterns=getattr(config, 'ALLOWED_CORS_ORIGIN_PATTERNS', [])
    )
    app.add_middleware(RequestContextMiddleware)

    logger.info("App configured and ready")
    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.PORT)
