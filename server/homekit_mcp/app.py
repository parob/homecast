"""
HomeKit MCP Server Application.

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

from homekit_mcp import config
from homekit_mcp.api.api import API
from homekit_mcp.middleware import (
    CORSMiddleware,
    RequestContextMiddleware,
)
from homekit_mcp.models.db.database import (
    create_db_and_tables,
    validate_schema,
    wipe_and_recreate_db,
)
from homekit_mcp.websocket.handler import websocket_endpoint, ping_clients


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def create_app() -> Starlette:
    """Create and configure the Starlette application."""

    # Create GraphQL app
    graphql_app = GraphQLHTTP.from_api(
        api=GraphQLAPI(root_type=API),
        auth_enabled=False  # We handle auth in middleware
    ).app

    # Health check endpoint
    async def health(request):
        return JSONResponse({"status": "ok"})

    # Lifespan handler for startup/shutdown
    @asynccontextmanager
    async def lifespan(app: Starlette):
        logger.info("HomeKit MCP server starting up...")

        # Database setup
        if getattr(config, "VALIDATE_OR_WIPE_DB_ON_STARTUP", False):
            if not validate_schema():
                logger.warning("Database schema validation failed - wiping and recreating")
                wipe_and_recreate_db()
            else:
                from sqlalchemy import inspect
                from homekit_mcp.models.db.database import get_engine
                engine = get_engine()
                inspector = inspect(engine)
                if not inspector.get_table_names():
                    logger.info("Database is empty - creating tables")
                    create_db_and_tables()
        elif getattr(config, "CREATE_DB_ON_STARTUP", False):
            create_db_and_tables()

        # Start background tasks
        ping_task = asyncio.create_task(ping_clients())

        logger.info("HomeKit MCP server ready")
        yield

        # Cleanup
        ping_task.cancel()
        try:
            await ping_task
        except asyncio.CancelledError:
            pass

        logger.info("HomeKit MCP server shutting down")

    # Create main app
    app = Starlette(
        routes=[
            Route('/health', endpoint=health, methods=['GET']),
            WebSocketRoute('/ws', endpoint=websocket_endpoint),
            Mount('/', app=graphql_app, name='graphql'),
        ],
        lifespan=lifespan
    )

    # Add middleware (order matters - first added is outermost)
    app.add_middleware(CORSMiddleware, allowed_origins=config.ALLOWED_CORS_ORIGINS)
    app.add_middleware(RequestContextMiddleware)

    logger.info("App configured and ready")
    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.PORT)
