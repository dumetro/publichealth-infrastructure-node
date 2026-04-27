from fastapi import FastAPI, status
from fastapi.responses import JSONResponse
import logging
import sys
from contextlib import asynccontextmanager
from .config import settings
from .database import Database
from .api import workspaces, git, buckets, spawn

# Configure logging
logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application startup and shutdown logic."""
    # Startup
    logger.info("Starting Workspace Service")
    try:
        Database.initialize()
        logger.info("Database connection pool initialized")

        # Initialize workspace schema
        with Database.get_connection() as conn:
            with conn.cursor() as cur:
                with open("/app/app/schema/init_workspace_schema.sql") as f:
                    schema_sql = f.read()
                cur.execute(schema_sql)
                conn.commit()
                logger.info("Workspace schema initialized")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
        raise

    yield

    # Shutdown
    logger.info("Shutting down Workspace Service")
    Database.close_all()


app = FastAPI(
    title="Workspace Service",
    description="Central workspace management for JupyterHub multi-server deployment",
    version="1.0.0",
    lifespan=lifespan,
)


# Include API routers
app.include_router(workspaces.router)
app.include_router(git.router)
app.include_router(buckets.router)
app.include_router(spawn.router)


@app.get("/health", status_code=status.HTTP_200_OK)
async def health_check():
    """Health check endpoint for Kubernetes probes."""
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content={"status": "ok", "service": "workspace-service"},
    )


@app.get("/ready", status_code=status.HTTP_200_OK)
async def readiness_check():
    """Readiness check endpoint for Kubernetes probes."""
    try:
        # Try to connect to database
        with Database.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content={"status": "ready"},
        )
    except Exception as e:
        logger.error(f"Readiness check failed: {e}")
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "not ready", "error": str(e)},
        )


@app.get("/", status_code=status.HTTP_200_OK)
async def root():
    """Root endpoint."""
    return {
        "service": "workspace-service",
        "version": "1.0.0",
        "health": "/health",
        "ready": "/ready",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
