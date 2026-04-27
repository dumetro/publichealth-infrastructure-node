from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from uuid import UUID


class WorkspaceCreate(BaseModel):
    project_name: str = Field(..., min_length=1, max_length=100)
    display_name: Optional[str] = None
    description: Optional[str] = None
    use_medallion: bool = True


class WorkspaceResponse(BaseModel):
    id: UUID
    username: str
    project_name: str
    display_name: Optional[str]
    description: Optional[str]
    minio_prefix: str
    status: str
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class WorkspaceListResponse(BaseModel):
    workspaces: list[WorkspaceResponse]
    total: int


class MinIOServiceAccount(BaseModel):
    username: str
    minio_access_key: str
    iam_policy_name: str
    k8s_secret_name: str
    created_at: datetime


class GitConfiguration(BaseModel):
    workspace_id: UUID
    repo_url: str
    branch: str = "main"
    credential_type: str = "https_token"
    clone_path: Optional[str] = None


class GitConfigResponse(GitConfiguration):
    id: UUID
    username: str
    k8s_secret_name: Optional[str]
    linked_at: datetime

    class Config:
        from_attributes = True
