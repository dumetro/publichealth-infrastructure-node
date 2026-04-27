from fastapi import APIRouter, Depends, HTTPException, status
from uuid import UUID
import logging
from ..models.workspace import GitConfiguration, GitConfigResponse
from ..database import Database
from ..k8s_secrets import secrets_manager

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/workspaces", tags=["git"])


async def get_current_user() -> str:
    """Extract username from request context."""
    return "anonymous"


@router.post("/{workspace_id}/git", response_model=GitConfigResponse, status_code=status.HTTP_201_CREATED)
async def link_git_repo(
    workspace_id: UUID,
    git_config: GitConfiguration,
    username: str = Depends(get_current_user),
):
    """Link a git repository to a workspace."""
    db = Database()

    # Verify workspace exists and belongs to user
    query = "SELECT id FROM workspace.workspaces WHERE id = %s AND username = %s"
    workspace = db.execute_query(query, (str(workspace_id), username))
    if not workspace:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )

    # Check for existing git config
    query = "SELECT id FROM workspace.git_configurations WHERE workspace_id = %s"
    existing = db.execute_query(query, (str(workspace_id),))
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Git repository already linked to this workspace",
        )

    # Create K8s secret if credentials provided
    k8s_secret_name = None
    if git_config.credential_type != "none":
        try:
            k8s_secret_name = secrets_manager.write_git_secret(
                username,
                git_config.credential_type,
                "placeholder-credential",  # Would be passed in request
            )
        except Exception as e:
            logger.error(f"Failed to create git secret: {e}")
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Failed to store git credentials",
            )

    # Store git config in database
    query = """
    INSERT INTO workspace.git_configurations
    (workspace_id, username, repo_url, branch, credential_type, k8s_secret_name, clone_path)
    VALUES (%s, %s, %s, %s, %s, %s, %s)
    RETURNING id, workspace_id, username, repo_url, branch, credential_type, k8s_secret_name, clone_path, linked_at
    """
    result = db.execute_query(
        query,
        (
            str(workspace_id),
            username,
            git_config.repo_url,
            git_config.branch,
            git_config.credential_type,
            k8s_secret_name,
            git_config.clone_path,
        ),
    )

    if not result:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to link git repository",
        )

    logger.info(f"Linked git repo {git_config.repo_url} to workspace {workspace_id}")
    return GitConfigResponse(**dict(zip([
        'id', 'workspace_id', 'username', 'repo_url', 'branch', 'credential_type',
        'k8s_secret_name', 'clone_path', 'linked_at'
    ], result[0])))


@router.patch("/{workspace_id}/git", response_model=GitConfigResponse)
async def update_git_config(
    workspace_id: UUID,
    git_config: GitConfiguration,
    username: str = Depends(get_current_user),
):
    """Update git configuration for a workspace (admin only)."""
    # Admin check would go here
    db = Database()

    query = """
    UPDATE workspace.git_configurations
    SET repo_url = %s, branch = %s, credential_type = %s
    WHERE workspace_id = %s AND username = %s
    RETURNING id, workspace_id, username, repo_url, branch, credential_type, k8s_secret_name, clone_path, linked_at
    """
    result = db.execute_query(
        query,
        (
            git_config.repo_url,
            git_config.branch,
            git_config.credential_type,
            str(workspace_id),
            username,
        ),
    )

    if not result:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Git configuration not found",
        )

    return GitConfigResponse(**dict(zip([
        'id', 'workspace_id', 'username', 'repo_url', 'branch', 'credential_type',
        'k8s_secret_name', 'clone_path', 'linked_at'
    ], result[0])))


@router.delete("/{workspace_id}/git", status_code=status.HTTP_204_NO_CONTENT)
async def unlink_git_repo(
    workspace_id: UUID,
    username: str = Depends(get_current_user),
):
    """Unlink git repository from a workspace."""
    db = Database()

    # Get the secret name before deleting
    query = "SELECT k8s_secret_name FROM workspace.git_configurations WHERE workspace_id = %s"
    result = db.execute_query(query, (str(workspace_id),))

    if result and result[0][0]:
        try:
            secrets_manager.delete_secret(result[0][0])
        except Exception as e:
            logger.error(f"Failed to delete git secret: {e}")

    # Delete git configuration
    query = "DELETE FROM workspace.git_configurations WHERE workspace_id = %s AND username = %s"
    db.execute_update(query, (str(workspace_id), username))

    logger.info(f"Unlinked git repository from workspace {workspace_id}")
