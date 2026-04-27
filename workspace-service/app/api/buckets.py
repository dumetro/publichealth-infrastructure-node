from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from typing import Optional, List
from uuid import UUID
import logging
from ..database import Database
from ..minio_admin import minio_admin

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1", tags=["buckets"])


class BucketAccessRequest(BaseModel):
    workspace_id: UUID
    bucket_name: str
    path_prefix: Optional[str] = None
    access_level: str = "read"


class BucketAccessResponse(BaseModel):
    id: UUID
    workspace_id: UUID
    bucket_name: str
    path_prefix: Optional[str]
    access_level: str
    status: str
    requested_at: str


class BucketInfo(BaseModel):
    name: str
    accessible: bool
    access_level: Optional[str] = None


async def get_current_user() -> str:
    """Extract username from request context."""
    return "anonymous"


@router.get("/buckets", response_model=List[BucketInfo])
async def list_buckets(
    username: str = Depends(get_current_user),
):
    """List buckets accessible to the authenticated user."""
    try:
        all_buckets = minio_admin.list_buckets()
    except Exception as e:
        logger.error(f"Failed to list buckets: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to retrieve bucket list",
        )

    # Get user's workspace bucket (modellers/{username}/*)
    db = Database()
    query = """
    SELECT DISTINCT bucket_name
    FROM workspace.bucket_access_grants
    WHERE username = %s AND status = 'approved'
    """
    approved_grants = db.execute_query(query, (username,))
    approved_buckets = [row[0] for row in approved_grants]

    # Build response
    buckets = []
    for bucket_name in all_buckets:
        if bucket_name.startswith("modellers/"):
            # User's own workspace bucket
            buckets.append(BucketInfo(name=bucket_name, accessible=True, access_level="readwrite"))
        elif bucket_name in approved_buckets:
            # Approved external access
            buckets.append(BucketInfo(name=bucket_name, accessible=True, access_level="read"))
        else:
            # Not accessible
            buckets.append(BucketInfo(name=bucket_name, accessible=False))

    return buckets


@router.post("/buckets/requests", response_model=BucketAccessResponse, status_code=status.HTTP_201_CREATED)
async def request_bucket_access(
    request: BucketAccessRequest,
    username: str = Depends(get_current_user),
):
    """Request access to a bucket."""
    db = Database()

    # Verify workspace exists
    query = "SELECT id FROM workspace.workspaces WHERE id = %s AND username = %s"
    workspace = db.execute_query(query, (str(request.workspace_id), username))
    if not workspace:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )

    # Check for existing request
    query = """
    SELECT id FROM workspace.bucket_access_grants
    WHERE workspace_id = %s AND bucket_name = %s AND path_prefix IS NOT DISTINCT FROM %s
    """
    existing = db.execute_query(
        query,
        (str(request.workspace_id), request.bucket_name, request.path_prefix),
    )
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Access request for this bucket already exists",
        )

    # Create access request
    query = """
    INSERT INTO workspace.bucket_access_grants
    (workspace_id, username, bucket_name, path_prefix, access_level, status)
    VALUES (%s, %s, %s, %s, %s, 'pending')
    RETURNING id, workspace_id, bucket_name, path_prefix, access_level, status, requested_at
    """
    result = db.execute_query(
        query,
        (
            str(request.workspace_id),
            username,
            request.bucket_name,
            request.path_prefix,
            request.access_level,
        ),
    )

    if not result:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to create access request",
        )

    logger.info(
        f"Created bucket access request for {username} to {request.bucket_name}"
    )
    return BucketAccessResponse(**dict(zip([
        'id', 'workspace_id', 'bucket_name', 'path_prefix', 'access_level', 'status', 'requested_at'
    ], result[0])))


@router.get("/workspaces/{workspace_id}/buckets", response_model=List[BucketInfo])
async def list_workspace_buckets(
    workspace_id: UUID,
    username: str = Depends(get_current_user),
):
    """List buckets for a specific workspace."""
    db = Database()

    # Verify workspace ownership
    query = "SELECT id FROM workspace.workspaces WHERE id = %s AND username = %s"
    workspace = db.execute_query(query, (str(workspace_id), username))
    if not workspace:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )

    # Get approved access grants for this workspace
    query = """
    SELECT DISTINCT bucket_name, access_level
    FROM workspace.bucket_access_grants
    WHERE workspace_id = %s AND status = 'approved'
    """
    results = db.execute_query(query, (str(workspace_id),))

    buckets = [
        BucketInfo(name=row[0], accessible=True, access_level=row[1])
        for row in results
    ]

    return buckets
