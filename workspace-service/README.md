# Workspace Service

Workspace management service for JupyterHub multi-server deployment. Provides centralized management of per-user workspaces, MinIO access, git repository linking, and dependency tracking.

## Features

- Per-user, per-project MinIO workspaces with medallion folder structure
- GitHub repository linking (HTTPS token, SSH key, or no credentials)
- MinIO bucket discovery and access-request/approval workflow
- Notebook dependency tracking across workspaces
- JupyterHub pre_spawn_hook integration for credential injection
- Admin dashboard for access request review and audit logging

## Architecture

```
workspaces.<domain>  ──→  workspace-service  (FastAPI, data-stack namespace)
                          │  reads/writes PostgreSQL workspace schema
                          │  calls MinIO admin API (IAM policy management)
                          └  writes Kubernetes secrets (per-user creds)

JupyterHub hub pod
  └── pre_spawn_hook (hub.extraConfig)
        calls workspace-service /api/v1/users/{username}/spawn-config
        injects per-user MinIO creds + git creds as pod volume mounts
```

## Building

```bash
cd workspace-service
docker build -t workspace-service:latest .
```

## Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export DATABASE_URL="postgresql://user:pass@localhost:5432/health_node"
export MINIO_ENDPOINT="localhost:9000"
export MINIO_ACCESS_KEY="minioadmin"
export MINIO_SECRET_KEY="minioadmin"

# Run development server
uvicorn app.main:app --reload
```

## Deployment

See [charts/workspace-service/](../charts/workspace-service/) for Helm chart.

```bash
helm install workspace-service ./charts/workspace-service \
  --namespace data-stack \
  --values values-prod.yaml
```

## API Endpoints

### Workspaces
- `POST /api/v1/workspaces` - Create workspace
- `GET /api/v1/workspaces` - List user's workspaces
- `GET /api/v1/workspaces/{id}` - Get workspace details

### Git Configuration
- `POST /api/v1/workspaces/{id}/git` - Link git repo
- `PATCH /api/v1/workspaces/{id}/git` - Update git config (admin)
- `DELETE /api/v1/workspaces/{id}/git` - Unlink repo

### Bucket Access
- `GET /api/v1/buckets` - List accessible buckets
- `POST /api/v1/buckets/requests` - Request bucket access
- `GET /api/v1/workspaces/{id}/buckets` - List workspace buckets

### Spawn Configuration
- `GET /api/v1/users/{username}/spawn-config` - Get JupyterHub spawn config

### Health
- `GET /health` - Health check (liveness)
- `GET /ready` - Readiness check
- `GET /` - Root endpoint

## Database Schema

Tables in `workspace` schema:
- `workspaces` - User workspaces and projects
- `minio_service_accounts` - Per-user MinIO credentials
- `git_configurations` - Git repo linking config
- `bucket_access_grants` - Bucket access requests and approvals
- `notebook_dependencies` - Notebook→resource dependency tracking
- `admin_audit_log` - Admin action audit trail

See [app/schema/init_workspace_schema.sql](app/schema/init_workspace_schema.sql) for full schema.

## Configuration

Environment variables:
- `DATABASE_URL` - PostgreSQL connection string
- `MINIO_ENDPOINT` - MinIO endpoint (host:port)
- `MINIO_ACCESS_KEY` - MinIO admin access key
- `MINIO_SECRET_KEY` - MinIO admin secret key
- `MINIO_MODELLERS_BUCKET` - Name of modellers bucket (default: modellers)
- `KUBERNETES_NAMESPACE` - Target namespace (default: data-stack)
- `JUPYTERHUB_API_URL` - JupyterHub API endpoint
- `JUPYTERHUB_API_TOKEN` - JupyterHub API token
- `WORKSPACE_ADMINS` - Comma-separated admin usernames (default: admin)
- `LOG_LEVEL` - Logging level (default: INFO)
