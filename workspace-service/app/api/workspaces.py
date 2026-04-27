from fastapi import APIRouter, Depends, HTTPException, status
from typing import Optional
from uuid import UUID
import logging
from ..models.workspace import (
    WorkspaceCreate,
    WorkspaceResponse,
    WorkspaceListResponse,
)
from ..database import Database
from ..minio_admin import minio_admin
from ..k8s_secrets import secrets_manager
from ..config import settings

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/workspaces", tags=["workspaces"])


async def get_current_user(request) -> str:
    """Extract username from request context."""
    # This would be populated by JupyterHub middleware or auth header
    return getattr(request.state, "username", "anonymous")


@router.post("", response_model=WorkspaceResponse, status_code=status.HTTP_201_CREATED)
async def create_workspace(
    workspace: WorkspaceCreate,
    request,
    username: str = Depends(get_current_user),
):
    """Create a new workspace for the authenticated user."""
    db = Database()

    # Check for duplicate project name
    query = "SELECT id FROM workspace.workspaces WHERE username = %s AND project_name = %s"
    existing = db.execute_query(query, (username, workspace.project_name))
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Workspace with this project name already exists",
        )

    # Generate MinIO prefix
    minio_prefix = f"{settings.minio_modellers_bucket}/{username}/{workspace.project_name}/"

    # Create workspace record
    query = """
    INSERT INTO workspace.workspaces
    (username, project_name, display_name, description, minio_prefix, status)
    VALUES (%s, %s, %s, %s, %s, 'active')
    RETURNING id, username, project_name, display_name, description, minio_prefix, status, created_at, updated_at
    """
    db_workspace = db.execute_query(
        query,
        (
            username,
            workspace.project_name,
            workspace.display_name,
            workspace.description,
            minio_prefix,
        ),
    )

    if not db_workspace:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to create workspace",
        )

    # Create medallion structure if requested
    if workspace.use_medallion:
        try:
            minio_admin.create_medallion_structure(
                settings.minio_modellers_bucket, f"{username}/{workspace.project_name}/"
            )
        except Exception as e:
            logger.error(f"Failed to create medallion structure: {e}")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Failed to create medallion structure in MinIO",
            )

    logger.info(f"Created workspace {workspace.project_name} for user {username}")
    return WorkspaceResponse(**db_workspace[0])


@router.get("", response_model=WorkspaceListResponse)
async def list_workspaces(
    username: str = Depends(get_current_user),
):
    """List all workspaces for the authenticated user."""
    db = Database()

    query = """
    SELECT id, username, project_name, display_name, description, minio_prefix, status, created_at, updated_at
    FROM workspace.workspaces
    WHERE username = %s
    ORDER BY created_at DESC
    """
    results = db.execute_query(query, (username,))

    workspaces = [WorkspaceResponse(**dict(zip([
        'id', 'username', 'project_name', 'display_name', 'description',
        'minio_prefix', 'status', 'created_at', 'updated_at'
    ], row))) for row in results]

    return WorkspaceListResponse(workspaces=workspaces, total=len(workspaces))


@router.get("/{workspace_id}", response_model=WorkspaceResponse)
async def get_workspace(
    workspace_id: UUID,
    username: str = Depends(get_current_user),
):
    """Get a specific workspace."""
    db = Database()

    query = """
    SELECT id, username, project_name, display_name, description, minio_prefix, status, created_at, updated_at
    FROM workspace.workspaces
    WHERE id = %s AND username = %s
    """
    result = db.execute_query(query, (str(workspace_id), username))

    if not result:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )

    return WorkspaceResponse(**dict(zip([
        'id', 'username', 'project_name', 'display_name', 'description',
        'minio_prefix', 'status', 'created_at', 'updated_at'
    ], result[0])))
