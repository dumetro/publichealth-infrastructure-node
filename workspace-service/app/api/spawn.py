from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from typing import Optional
import logging
from ..database import Database
from ..config import settings

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1", tags=["spawn"])


class SpawnConfig(BaseModel):
    minio_secret_name: Optional[str] = None
    git_secret_name: Optional[str] = None
    git_credential_type: Optional[str] = None
    git_repo_url: Optional[str] = None


async def get_current_user_from_hub() -> str:
    """Extract username from JupyterHub request."""
    return "anonymous"


@router.get("/users/{username}/spawn-config", response_model=SpawnConfig)
async def get_spawn_config(
    username: str,
):
    """
    Get spawn configuration for a user.
    Called by JupyterHub's pre_spawn_hook to inject credentials and config.
    """
    db = Database()

    spawn_config = SpawnConfig()

    # Get MinIO credentials for user
    query = """
    SELECT k8s_secret_name FROM workspace.minio_service_accounts
    WHERE username = %s
    """
    result = db.execute_query(query, (username,))
    if result:
        spawn_config.minio_secret_name = result[0][0]

    # Get git credentials (use latest workspace's git config)
    query = """
    SELECT k8s_secret_name, credential_type, repo_url
    FROM workspace.git_configurations
    WHERE username = %s
    ORDER BY linked_at DESC
    LIMIT 1
    """
    result = db.execute_query(query, (username,))
    if result:
        spawn_config.git_secret_name = result[0][0]
        spawn_config.git_credential_type = result[0][1]
        spawn_config.git_repo_url = result[0][2]

    logger.debug(f"Generated spawn config for {username}")
    return spawn_config
