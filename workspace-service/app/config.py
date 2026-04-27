from pydantic_settings import BaseSettings
from typing import Optional


class Settings(BaseSettings):
    # Database
    database_url: str = "postgresql://health_node:password@postgresql.data-stack.svc.cluster.local:5432/health_node"
    database_pool_size: int = 10
    database_max_overflow: int = 20

    # MinIO
    minio_endpoint: str = "minio.data-stack.svc.cluster.local:9000"
    minio_access_key: str = "minioadmin"
    minio_secret_key: str = "minioadmin"
    minio_secure: bool = False
    minio_modellers_bucket: str = "modellers"

    # Kubernetes
    kubernetes_namespace: str = "data-stack"
    kubernetes_in_cluster: bool = True

    # JupyterHub
    jupyterhub_api_url: str = "http://hub:8081/hub/api"
    jupyterhub_api_token: Optional[str] = None

    # Workspace Service
    workspace_admins: str = "admin"
    workspace_service_hostname: str = "workspaces.example.com"
    workspace_service_port: int = 8000

    # Logging
    log_level: str = "INFO"

    class Config:
        env_file = ".env"
        case_sensitive = False


settings = Settings()
