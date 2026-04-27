# Comprehensive Technical Design Document
## Public Health AI Infrastructure Platform

**Version:** 1.0  
**Last Updated:** 2026-04-27  
**Status:** Design (Pre-Implementation)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Overview](#system-overview)
3. [Phase 1: Data Lakehouse (Existing/Current)](#phase-1-data-lakehouse)
4. [Phase 2: HPC & ML Development](#phase-2-hpc--ml-development)
5. [Phase 3+: Model Serving & Analytics](#phase-3-model-serving--analytics)
6. [Complete Architecture](#complete-architecture)
7. [Data Models & Schemas](#data-models--schemas)
8. [API Specifications](#api-specifications)
9. [Deployment Architecture](#deployment-architecture)
10. [Security Model](#security-model)
11. [Operations & Monitoring](#operations--monitoring)
12. [Appendices](#appendices)

---

## Executive Summary

This document describes a three-server, three-phase infrastructure platform for public health AI model development, governance, and serving.

**Three-Server Architecture:**
- **Server 1 (Datalake):** MinIO (S3-compatible storage), PostgreSQL (central metadata), Airflow (orchestration), Monitoring (Prometheus, Grafana)
- **Server 2 (HPC & ML):** JupyterHub (notebooks), Slurm (job scheduling), MLflow (experiment tracking), Unity Catalog (data governance), Keycloak (identity), Workspace Service (project management)
- **Server 3 (Model Serving):** KServe (inference), Harbor (container registry), Trino (SQL query engine), Model Approval Service, FastAPI endpoints

**Three-Phase Rollout:**
- **Phase 1:** Data lakehouse foundation (existing, to be maintained)
- **Phase 2:** ML development environment with HPC scheduler (new)
- **Phase 3+:** Model serving, analytics, and scaling

**Key Features:**
- Complete data lineage tracking (data → training → model → deployment → inference)
- Formal model approval workflow with audit trails
- Intelligent GPU pooling across training and inference servers
- Hot/cold storage tiering for cost optimization
- Cross-cluster identity management via Keycloak
- Failover capability (Server 2 crash → Server 1 fallback for lightweight jobs)
- Role-based access control (RBAC) at data, model, and inference layers
- Cost visibility and ROI analysis per model/user

---

## System Overview

### High-Level Data Flow

```
1. INGEST (Server 1: Airflow)
   Raw health data → MinIO (s3://raw/)

2. EXPLORE & PREPARE (Server 2: JupyterHub)
   Read from s3://raw/ → EDA, feature engineering → s3://standard/

3. TRAIN (Server 2: Slurm + MLflow)
   Read s3://standard/ + s3://raw/ → Training job → Model artifact
   Artifacts stored in s3://modellers/{user}/mlflow/

4. REGISTER & APPROVE (Server 2 + 3: Workspace Service + Model Approval Service)
   MLflow artifact → Docker image → Harbor registry
   Image → Model Approval dashboard → Admin approval

5. DEPLOY (Server 3: KServe)
   Harbor image → KServe InferenceService → Serving endpoint

6. MONITOR & ANALYZE (Server 1 + 3: Prometheus, Grafana)
   Predictions logged → Server 1 PostgreSQL (inference_logs)
   Metrics exported → Prometheus → Grafana dashboards

7. GOVERNANCE (All Servers: PostgreSQL)
   Full lineage: data → code → training → model → deployment → inference
   Cost tracking, ROI analysis, data drift detection
```

### Server Characteristics

| Attribute | Server 1 (Datalake) | Server 2 (HPC) | Server 3 (Serving) |
|-----------|---|---|---|
| **Location** | Cloud (AWS/GCP/Azure) | On-premises or dedicated cloud | Cloud |
| **k8s Cluster** | k3s (single node) | k8s (multi-node) | k8s (multi-node) |
| **CPU** | 4-8 cores | 2x Xeon 64c (128 cores total) | 16-32 cores |
| **RAM** | 16-32GB | 256GB | 64-128GB |
| **GPU** | None | 2 GPUs (shared with Server 3 via Ray) | 4-6 GPUs (A100 or L40) |
| **Storage** | 1-2TB MinIO + 500GB PostgreSQL | 500GB (local scratch, not persistent) | 500GB (models + caches) |
| **Network** | Cloud VPC | VPN tunnel to cloud | Cloud VPC |
| **Primary Role** | Central storage, metadata, orchestration | Model development, training | Inference, serving |

---

## Phase 1: Data Lakehouse (Current/Existing)

### Components

#### 1. MinIO (S3-Compatible Object Storage)

**Purpose:** Central data lake for all raw and processed health data.

**Deployment:** Bitnami MinIO Helm chart, k3s, `data-stack` namespace

**Buckets:**
```
minio/
├── raw/                    # Raw ingested health data
│   ├── health-data/2024-Q1/
│   ├── health-data/2024-Q2/
│   └── health-data-v2/    # Version 2 schema
├── standard/              # Cleaned, feature-engineered data
│   ├── features-2024-Q1/
│   └── features-cohort-a/
├── published/             # Data ready for analysis/consumption
│   ├── models-evaluation/
│   └── public-dashboards/
└── modellers/             # User workspaces (Phase 2)
    ├── alice/
    │   ├── mlflow/runs/
    │   ├── deployed-models/
    │   └── notebooks/
    └── bob/
```

**Access Patterns:**
- Airflow: read/write raw/, standard/, published/
- Users (Phase 2): read raw/, standard/; write modellers/{username}/
- KServe (Phase 3): read published/, modellers/{model-version}/

**Configuration (Terraform):**
```hcl
helm_release.minio {
  chart = "bitnami/minio"
  values = {
    image.tag = "RELEASE.2025-09-07T16-13-09Z"
    persistence.size = "1Ti"
    storage_class = "local-path"
    apiIngress.enabled = false
    buckets = ["raw", "standard", "published", "modellers"]
  }
}
```

**API Endpoints:**
- S3 API: `http://minio.data-stack.svc.cluster.local:9000`
- Console: `http://minio.dakar-datasphere-node.local:9001` (nginx ingress)

---

#### 2. PostgreSQL (Central Metadata Database)

**Purpose:** Single source of truth for all metadata, lineage, workspaces, approvals, and audit logs.

**Deployment:** Custom Kubernetes StatefulSet with PostGIS + pgvector extensions

**Database:** `health_node`

**Schemas:**
- `public`: Health-domain data models (if used)
- `workspace`: User workspaces, git configs, bucket access (Phase 2)
- `airflow`: Airflow internal (via Airflow Helm chart)
- `lineage`: Training jobs, model versions, deployments, inference logs (Phase 2+)

**Key Tables (Phase 1):**
- `airflow.dag_run`, `airflow.task_instance`: Airflow orchestration state
- (Phase 2+): See [Data Models & Schemas](#data-models--schemas) section

**Configuration (Terraform):**
```hcl
kubernetes_stateful_set.postgresql {
  image = "postgres-health-ext:16"  # Custom with PostGIS, pgvector
  persistence.size = "500Gi"
  storage_class = "local-path"
  resources.limits = {cpu = 4, memory = "32Gi"}
}

kubernetes_service.postgresql {
  type = "ClusterIP"
  port = 5432
  selector = {app = "postgresql"}
}

kubernetes_service.pgbouncer {
  type = "ClusterIP"
  port = 5432
  # Connection pooling: transaction mode, 2 PgBouncer replicas
}
```

**Extensions:**
```sql
CREATE EXTENSION IF NOT EXISTS postgis;        -- Geospatial queries
CREATE EXTENSION IF NOT EXISTS pgvector;       -- Vector similarity (ML embeddings)
CREATE EXTENSION IF NOT EXISTS pg_trgm;        -- Text search
```

**Access:**
- Airflow: direct to PostgreSQL (bypasses PgBouncer for DDL)
- All other services (Phase 2+): via PgBouncer (port 5432)

---

#### 3. Airflow (Orchestration)

**Purpose:** Schedule and monitor data pipelines (ingest, validate, transform).

**Deployment:** Bitnami Airflow Helm chart, k3s, `data-stack` namespace

**Key DAGs (Phase 1):**
```python
# daily_encounter_etl.py
DAG: daily_encounter_etl
  ├─ Task 1: download_raw_data
  │   └─ Fetch health data from external source → s3://raw/
  ├─ Task 2: validate_schemas
  │   └─ Check row counts, column types, nulls
  ├─ Task 3: transform_to_standard
  │   └─ Deduplication, normalization → s3://standard/
  └─ Task 4: publish_datasets
      └─ Copy validated data → s3://published/
```

**Configuration (Terraform):**
```hcl
helm_release.airflow {
  chart = "apache-airflow/airflow"
  values = {
    defaultUser.password = var.airflow_admin_password
    webserver.replicas = 1
    scheduler.replicas = 1
    executor = "KubernetesExecutor"  # Each task = one pod
    postgresql_enabled = true  # Uses PostgreSQL for metadata
  }
}
```

**DAG Examples:**
- Data ingestion (daily at 00:00 UTC)
- Data validation (after ingestion)
- Feature engineering (weekly)
- Data quality checks (daily)

---

#### 4. Monitoring Stack

**Purpose:** Observe health, performance, and costs of all services.

**Components:**
- **Prometheus:** Metrics collection (server 1, 2, 3)
- **Grafana:** Dashboards and alerting
- **AlertManager:** Alert routing (Slack, email)
- **Node Exporter:** Host metrics
- **kube-prometheus-stack:** Kubernetes metrics

**Deployment:** Bitnami kube-prometheus-stack Helm chart

**Key Dashboards (Phase 1):**
- Kubernetes cluster overview (CPU, memory, disk)
- MinIO usage and performance
- PostgreSQL connections and queries
- Airflow DAG execution times

**Key Metrics:**
```
# MinIO
minio_server_drive_used_bytes{bucket="raw"} = 500e9  # 500GB
minio_server_drive_total_bytes = 1e12                # 1TB

# PostgreSQL
pg_stat_activity_count{datname="health_node"} = 25  # Active connections
pg_database_size_bytes{datname="health_node"} = 1e11  # 100GB

# Airflow
airflow_dag_run_success{dag_id="daily_encounter_etl"} = 1
airflow_dag_run_failed{dag_id="daily_encounter_etl"} = 0
```

---

### Phase 1 Deployment

**Infrastructure (Terraform):**
```
terraform/
├── providers.tf          # Kubernetes + Helm providers
├── variables.tf          # Input variables
├── main.tf               # All resources (MinIO, PostgreSQL, Airflow, etc.)
├── outputs.tf            # Service endpoints
└── terraform.tfvars.example
```

**Deployment Script:**
```bash
deploy/deploy-node.sh
├─ Step 1: Verify kubeconfig + kubectl access
├─ Step 2: Create namespaces (data-stack, monitoring, ingress-basic)
├─ Step 3: MinIO deployment
├─ Step 4: PostgreSQL + PgBouncer deployment
├─ Step 5: Airflow deployment
├─ Step 6: Monitoring stack deployment
├─ Step 7: cert-manager (TLS certificates)
├─ Step 8: Ingress-nginx (API gateway)
├─ Step 9: KServe CRDs (prepared for Phase 3)
├─ Step 10: Service ingresses (MinIO, Airflow, Grafana)
└─ Validation: tests/validate-node.sh
```

**Secrets Management:**
```bash
deploy/setup-secrets.sh
├─ minio-creds                 # Root access key + secret
├─ postgres-creds              # Superuser + app user passwords
├─ airflow-secrets             # Fernet key, webserver secret, admin password
├─ airflow-metadata            # SQLAlchemy DSN for PostgreSQL
└─ pgbouncer-users             # SCRAM authentication userlist
```

---

## Phase 2: HPC & ML Development

### Components

#### 1. Identity Management (Keycloak)

**Purpose:** Centralized authentication and authorization across all servers.

**Deployment:** Bitnami Keycloak Helm chart, Server 2 k8s, `keycloak` namespace

**Architecture:**
```
User Browser
    ↓ (login with username/password)
Keycloak (auth.hpc.dakar.local)
    ├─ Realm: dakar-health
    ├─ LDAP/User Database
    ├─ Token Issuance (JWT)
    └─ OIDC/OAuth callbacks
         ↓
    Server 2 (JupyterHub via OAuthenticator)
    Server 1 (Airflow via OIDC)
    Server 3 (FastAPI via token validation)
```

**Realms & Clients:**

```
Realm: dakar-health
├─ Client: jupyterhub
│   ├─ Client ID: jupyterhub
│   ├─ Redirect URIs: https://hpc.dakar.local/hub/oauth_callback
│   └─ Scopes: openid, profile, email
│
├─ Client: airflow
│   ├─ Client ID: airflow-oidc
│   ├─ Redirect URIs: https://datalake.dakar.local/airflow/login/generic/callback
│   └─ Scopes: openid, profile, email
│
├─ Client: kserve-admin
│   ├─ Client ID: kserve-admin
│   ├─ Redirect URIs: https://serving.dakar.local/admin/callback
│   └─ Scopes: openid, profile, email, roles
│
├─ Client: model-approval-api
│   ├─ Client ID: model-approval-api
│   ├─ Access Type: confidential
│   ├─ Client Secret: (stored in k8s secret)
│   └─ Service Account: true
│
└─ Roles:
   ├─ data-scientist
   ├─ data-engineer
   ├─ model-reviewer
   ├─ infrastructure-admin
   └─ unity-catalog-admin

User Attributes:
├─ cost_center: (billing)
├─ team: ml-platform, data-infra, etc.
├─ approved_gpu_hours: (quota)
└─ data_access_level: (minimal, standard, elevated)
```

**Configuration (Helm):**
```yaml
# charts/keycloak/values.yaml
keycloak:
  replicas: 1  # HA (3) in production
  ingress:
    enabled: true
    hostname: auth.hpc.dakar.local
    tls: true
  persistence:
    enabled: true
    size: 50Gi
  resources:
    requests: {cpu: 500m, memory: 1Gi}
    limits: {cpu: 1000m, memory: 2Gi}
```

**OAuth2 Token Flow:**

```
JupyterHub User Login
    ↓
Redirect to Keycloak OIDC /authorize endpoint
    ↓
User enters credentials
    ↓
Keycloak issues authorization code
    ↓
JupyterHub exchanges code for ID token + refresh token
    ↓
ID token contains: user_id, email, roles, custom attributes
    ↓
JupyterHub spawns single-user pod with token in environment
    ↓
Token used for cross-service authorization (workspace-service, etc.)
```

---

#### 2. JupyterHub (Moved from Phase 1)

**Purpose:** Multi-user Jupyter notebook environment for data exploration and model development.

**Deployment:** Bitnami JupyterHub Helm chart, Server 2 k8s, `data-stack` namespace

**Architecture Change from Phase 1:**
- Authentication: DummyAuthenticator → Keycloak OAuthenticator
- Per-user credentials: Shared MinIO root → Per-user MinIO service accounts (via workspace-service)
- Home storage: Persistent PVCs (same as Phase 1)
- Image: Jupyter + PySpark + geospatial + MLflow (same, no changes)

**Configuration (jupyterhub-values.yaml):**

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: oauthenticator.generic.GenericOAuthenticator
    GenericOAuthenticator:
      client_id: jupyterhub
      client_secret: ${KEYCLOAK_CLIENT_SECRET}  # From k8s secret
      oauth_callback_url: https://hpc.dakar.local/hub/oauth_callback
      authorize_url: https://auth.hpc.dakar.local/realms/dakar-health/protocol/openid-connect/auth
      token_url: https://auth.hpc.dakar.local/realms/dakar-health/protocol/openid-connect/token
      userdata_url: https://auth.hpc.dakar.local/realms/dakar-health/protocol/openid-connect/userinfo
      user_key_path: preferred_username

  extraConfig:
    workspace-spawn-hook: |
      async def workspace_pre_spawn_hook(spawner):
          import urllib.request
          import json
          username = spawner.user.name
          ws_svc = "http://workspace-service.data-stack.svc.cluster.local:8000"
          
          try:
              config = get_spawn_config_from_workspace_service(username)
          except Exception as e:
              spawner.log.warning(f"workspace-service unavailable: {e}")
              config = {}
          
          # Inject per-user MinIO credentials
          if "minio_secret_name" in config:
              spawner.volumes.append({
                  "name": "minio-user-creds",
                  "secret": {"secretName": config["minio_secret_name"]}
              })
              spawner.volume_mounts.append({
                  "name": "minio-user-creds",
                  "mountPath": "/vault/minio-creds",
                  "readOnly": True
              })
          
          # Inject git credentials
          if "git_secret_name" in config:
              spawner.volumes.append({
                  "name": "git-creds",
                  "secret": {"secretName": config["git_secret_name"]}
              })
              spawner.volume_mounts.append({
                  "name": "git-creds",
                  "mountPath": "/home/jovyan/.git-credentials-file",
                  "readOnly": True
              })
      
      c.KubeSpawner.pre_spawn_hook = workspace_pre_spawn_hook

singleuser:
  image:
    name: jupyter-health-env
    tag: latest
  storage:
    dynamic:
      storageClass: local-path
    capacity: 10Gi
  profileList:
    - display_name: "Standard — 1 CPU / 2 GB"
      kubespawner_override:
        cpu_limit: 1
        cpu_guarantee: 0.5
        mem_limit: 2G
        mem_guarantee: 1G
    - display_name: "Large Compute — 2 CPU / 4 GB"
      kubespawner_override:
        cpu_limit: 2
        cpu_guarantee: 1
        mem_limit: 4G
        mem_guarantee: 2G
```

**Per-User Home PVCs:**
```
/home/jovyan/
├─ notebooks/              # Jupyter notebooks
├─ scripts/                # Python scripts
├─ data/                   # Local data (if needed)
├─ .git-credentials-file   # Git token (mounted from k8s secret)
├─ .ssh/id_rsa             # SSH key (mounted from k8s secret)
└─ .jupyter/               # Jupyter config
```

---

#### 3. Slurm (HPC Job Scheduler)

**Purpose:** Distributed job scheduling for training, feature engineering, and batch inference.

**Deployment:** System service (not containerized), Server 2 hardware

**Architecture:**

```
Server 2 Hardware
├─ Slurm Controller (master)
│  └─ Manages job queue, scheduling, resource allocation
├─ Slurm Daemons (compute nodes)
│  ├─ Node 1: 32 CPU cores, 1 GPU, 128GB RAM
│  ├─ Node 2: 32 CPU cores, 1 GPU, 128GB RAM
│  └─ Optional: additional CPU-only nodes
└─ Slurm Database
   └─ Job history, accounting, state
```

**Configuration (slurm.conf):**

```ini
# Partitions (queues)
PartitionName=gpu Nodes=node[1-2] Default=YES MaxTime=UNLIMITED State=UP
PartitionName=cpu Nodes=node[3-4] MaxTime=UNLIMITED State=UP
PartitionName=debug Nodes=node[1-2] MaxTime=00:30:00 State=UP

# QoS (Quality of Service) - enforce quotas
QOS=gpu_limited,cpu_default

# User limits
DefMemPerNode=UNLIMITED
MaxMemPerNode=256000  # 256GB per node

# GPU allocation
GresTypes=gpu
NodeName=node[1-2] Gres=gpu:A40:1  # or V100, H100, etc.
```

**Job Submission (from JupyterHub via submitit):**

```python
import submitit

executor = submitit.SlurmExecutor(folder="logs/slurm_jobs")
executor.update(
    gpus_per_node=1,
    cpus_per_task=8,
    mem_gb=64,
    partition="gpu",
    timeout_min=720,  # 12 hours
)

def train_model(data_bucket, mlflow_run_id):
    # Training code here
    return metrics

job = executor.submit(train_model, "s3://standard/features/", "abc123")
job_id = job.job_id
print(f"Submitted to Slurm: {job_id}")
```

**Resource Quotas:**

```sql
-- PostgreSQL: track per-user quota usage
CREATE TABLE workspace.slurm_quotas (
    username TEXT,
    gpu_hours_limit INT,  -- e.g., 100 hours/month
    gpu_hours_used INT,
    cpu_core_hours_limit INT,  -- e.g., 1000 hours/month
    cpu_core_hours_used INT,
    quota_reset_date DATE
);

-- Alert if approaching quota
-- SELECT * FROM workspace.slurm_quotas WHERE gpu_hours_used > gpu_hours_limit * 0.8
```

---

#### 4. MLflow (Experiment Tracking)

**Purpose:** Track training experiments (parameters, metrics, artifacts) and register model versions.

**Deployment:** Bitnami MLflow Helm chart (optional), Server 2 k8s, `data-stack` namespace

**Architecture:**

```
JupyterHub / Slurm Job
    ↓
MLflow Python Client (mlflow.log_metrics, mlflow.log_artifact)
    ↓
MLflow Tracking Server (Server 2, port 5000)
    ├─ Metadata: PostgreSQL (Server 1)
    ├─ Artifacts: MinIO s3://modellers/ (Server 1)
    └─ Web UI: http://mlflow.hpc.dakar.local (nginx ingress)
```

**Configuration (mlflow-values.yaml):**

```yaml
mlflow:
  image: ghcr.io/mlflow/mlflow:v2.10.0
  replicas: 1
  ingress:
    enabled: true
    hostname: mlflow.hpc.dakar.local
  persistence:
    enabled: false  # Use S3 for artifacts, PostgreSQL for metadata
  env:
    MLFLOW_BACKEND_STORE_URI: "postgresql://health_app:password@pgbouncer.data-stack.svc.cluster.local:5432/health_node"
    MLFLOW_DEFAULT_ARTIFACT_ROOT: "s3://modellers/"
    AWS_ACCESS_KEY_ID: ${MINIO_ACCESS_KEY}
    AWS_SECRET_ACCESS_KEY: ${MINIO_SECRET_KEY}
    MLFLOW_S3_ENDPOINT_URL: "http://minio.data-stack.svc.cluster.local:9000"
```

**Run Tracking Example:**

```python
import mlflow
import mlflow.pytorch

mlflow.set_tracking_uri("http://mlflow.hpc.dakar.local:5000")
mlflow.set_experiment("malaria-classifier-v2")

with mlflow.start_run() as run:
    # Log parameters
    mlflow.log_param("learning_rate", 0.001)
    mlflow.log_param("batch_size", 32)
    mlflow.log_param("epochs", 100)
    
    # Log metrics during training
    for epoch in range(100):
        loss = train_one_epoch()
        mlflow.log_metric("loss", loss, step=epoch)
    
    # Log model
    mlflow.pytorch.log_model(model, "model")
    
    # Tag for promotion
    mlflow.set_tag("stage", "production-candidate")
    mlflow.set_tag("mlflow.source.git.commit", git_commit_hash)
    mlflow.set_tag("mlflow.source.git.repo", "github.com/org/malaria-classifier")

# Model artifacts now in:
# s3://modellers/mlflow/experiments/{experiment_id}/runs/{run_id}/artifacts/model/
```

---

#### 5. Unity Catalog (Data Governance)

**Purpose:** Centralized data governance, table versioning, and access control.

**Deployment:** Optional Helm chart or SaaS (if using Databricks)

**Architecture:**

```
Unity Catalog (Server 2)
├─ Metastore: metadata about tables, versions, owners
├─ Catalogs: collections of schemas
│  └─ Catalog: health_data
│     ├─ Schema: raw
│     │  └─ Table: encounters (versioned)
│     │     ├─ v0: 2024-Q1 raw data
│     │     ├─ v1: 2024-Q2 with corrections
│     │     └─ v2: 2024-Q1-Q2 combined
│     ├─ Schema: standard
│     │  └─ Table: features (versioned)
│     └─ Schema: published
│        └─ Table: evaluation_set (versioned)
├─ Governance:
│  ├─ Who can read each table version
│  ├─ Who can write (create new versions)
│  └─ Lineage: which models used which table versions
└─ Integration:
   ├─ Trino (Server 3): query across versions
   └─ Spark (Slurm jobs): use table versions via Unity Catalog API
```

**Example Usage (Spark + Unity Catalog):**

```python
# In Spark job or notebook
spark.sql("""
    SELECT * FROM health_data.raw.encounters VERSION AS OF 2
    WHERE admission_date >= '2024-01-01'
""").show()

# Query lineage: which models used this table?
# (via Unity Catalog API)
table_version = unity_catalog.get_table("health_data.raw.encounters", version=2)
lineage = table_version.get_upstream_tables()  # Points to other table versions
lineage = table_version.get_downstream_uses()  # Points to models, reports
```

**Integration with PostgreSQL Lineage:**

```sql
-- Unity Catalog sends lineage events to PostgreSQL
CREATE TABLE workspace.unity_catalog_lineage (
    source_table TEXT,  -- health_data.raw.encounters
    source_version INT,
    destination_type TEXT,  -- 'model', 'report', 'table'
    destination_id UUID,
    recorded_at TIMESTAMPTZ DEFAULT now()
);

-- Query: "Show all models trained on encounters v2"
SELECT DISTINCT mv.model_name
FROM workspace.model_versions mv
JOIN workspace.unity_catalog_lineage ucl ON mv.id = ucl.destination_id
WHERE ucl.source_table = 'health_data.raw.encounters'
  AND ucl.source_version = 2;
```

---

#### 6. Workspace Service (Phase 2)

**Purpose:** Manage user workspaces, project configurations, bucket access requests, and lineage tracking.

**Deployment:** Custom FastAPI application, Server 2 k8s, `data-stack` namespace

**Core Responsibilities:**

```
1. Workspace CRUD
   ├─ Create workspace (initialize MinIO folder structure, user credentials)
   ├─ Update workspace (rename, description)
   ├─ List workspaces (user's own)
   └─ Archive workspace

2. GitHub Integration
   ├─ Link git repo (HTTPS, SSH, PAT)
   ├─ Store credentials securely (k8s secret)
   ├─ Pre-configure .gitconfig in user's pod
   └─ Support clone, commit, push, pull

3. MinIO Bucket Access
   ├─ List accessible buckets (own + approved grants)
   ├─ Request access to shared bucket
   ├─ Track approval status
   └─ Create per-user MinIO IAM service accounts

4. Dependency Tracking
   ├─ Record notebook→resource dependencies
   ├─ Query lineage graph
   └─ Generate impact analysis (if data is deleted, which models affected?)

5. Pre-Spawn Configuration
   ├─ /spawn-config endpoint
   ├─ Return per-user MinIO credentials
   ├─ Return git credentials
   └─ Return approved bucket list (for environment variables)

6. Admin Features
   ├─ Approve/deny bucket access requests
   ├─ View audit logs
   ├─ Manage user quotas
   └─ Resolve access conflicts
```

**API Specification:**

```python
# POST /api/v1/workspaces
{
    "project_name": "malaria-classifier",
    "display_name": "Malaria Risk Classification",
    "description": "ML model to predict malaria risk",
    "use_medallion_structure": true  # Creates bronze/silver/gold/scripts/notebooks
}

# Response
{
    "workspace_id": "uuid-xxx",
    "minio_prefix": "modellers/alice/malaria-classifier/",
    "status": "active",
    "created_at": "2026-04-27T..."
}

# GET /api/v1/workspaces/{workspace_id}/spawn-config
# Called by JupyterHub pre_spawn_hook
{
    "minio_secret_name": "minio-user-alice-creds",
    "minio_buckets_accessible": ["raw", "standard", "modellers/alice/"],
    "git_secret_name": "git-creds-alice",
    "git_credential_type": "https_token"
}

# POST /api/v1/workspaces/{workspace_id}/git
{
    "repo_url": "https://github.com/org/malaria-classifier.git",
    "auth_method": "https",  # https, ssh, pat
    "token": "ghp_xxxxx...",  # For HTTPS
    "branch": "main"
}

# POST /api/v1/buckets/requests
{
    "bucket_name": "raw",
    "path_prefix": "health-data/2024-Q1/",
    "access_level": "read",
    "reason": "Training model on health encounter data"
}

# Response
{
    "request_id": "uuid-yyy",
    "status": "pending",
    "requested_at": "2026-04-27T..."
}

# GET /admin/requests
# Returns pending bucket access requests for admin approval
[
    {
        "request_id": "uuid-yyy",
        "username": "alice",
        "bucket_name": "raw",
        "reason": "...",
        "requested_at": "2026-04-27T...",
        "actions": ["approve", "deny"]
    }
]

# POST /admin/requests/{request_id}/approve
{
    "notes": "Approved for Q1 2024 data analysis"
}
# Creates MinIO IAM policy, updates bucket_access_grants table

# POST /api/v1/dependencies
# Called from notebook to record dependency
{
    "notebook_path": "notebooks/analysis.ipynb",
    "resource_type": "bucket",
    "resource_ref": "raw"
}
```

**Database Tables (New in Phase 2):**

All stored in Server 1 PostgreSQL `workspace` schema. See [Data Models & Schemas](#data-models--schemas).

---

#### 7. Docker Image Updates (Server 2)

**File:** `docker/jupyter-health-env/Dockerfile`

**Additions for Phase 2:**

```dockerfile
FROM quay.io/jupyter/pyspark-notebook:spark-3.5.0

# System packages
RUN apt-get update && apt-get install -y \
    libgdal-dev libproj-dev g++ \
    git git-credential-store \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Python packages
RUN pip install --no-cache-dir \
    geopandas shapely folium \
    statsmodels scipy \
    mlflow \
    boto3 \
    pyarrow delta-spark \
    submitit \
    jupyterlab-git \
    s3contents \
    && \
    jupyter nbconvert --to notebook --execute /path/to/cleanup_notebooks.ipynb

# PySpark jars
RUN pip install pyspark==3.5.0 && \
    spark-shell --packages \
    org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.0 \
    org.hadoop:hadoop-aws:3.3.4 \
    software.amazon.awssdk:bundle:1.12.262

# Keycloak/OIDC support (if needed for direct auth)
RUN pip install --no-cache-dir \
    python-keycloak \
    requests-oauthlib

# jupyterlab-git extension (already in pyspark-notebook, but ensure latest)
RUN jupyter labextension enable @jupyterlab/git

# Git credential storage (for HTTPS clones)
RUN mkdir -p /home/jovyan/.config/git && \
    echo '[credential]\n    helper = store' > /home/jovyan/.gitconfig

ENTRYPOINT ["start-notebook.sh"]
```

---

#### 8. Ray Cluster (GPU Pooling)

**Purpose:** Unified GPU resource pool across Server 2 and Server 3 for intelligent task distribution.

**Deployment:** Ray Helm chart + custom configuration, spanning Server 2 and Server 3 k8s

**Architecture:**

```
Ray Head Node (Server 2)
├─ Redis: distributed state store
├─ Scheduler: assigns tasks to workers
├─ Plasma Store: distributed object cache
└─ Dashboard: http://ray.hpc.dakar.local:8265

Ray Worker Nodes (Server 2 + Server 3)
├─ Server 2 GPU Workers
│  ├─ Worker 1: 1 GPU + 8 CPU cores
│  └─ Worker 2: 1 GPU + 8 CPU cores
├─ Server 3 GPU Workers
│  ├─ Worker 1: 1 GPU + 4 CPU cores
│  ├─ Worker 2: 1 GPU + 4 CPU cores
│  ├─ Worker 3: 1 GPU + 4 CPU cores
│  └─ Worker 4: 1 GPU + 4 CPU cores
└─ CPU-Only Workers (optional, for preprocessing)
```

**Configuration (ray-values.yaml):**

```yaml
rayCluster:
  headGroupSpec:
    rayStartParams:
      num-cpus: 8
      object-memory: "10000000000"  # 10GB
    containers:
    - name: ray
      image: rayproject/ray:latest-gpu
      resources:
        requests: {cpu: 8, memory: 32Gi}
        limits: {cpu: 16, memory: 64Gi}

  workerGroupSpecs:
  - groupName: gpu-workers-server2
    minReplicas: 2
    maxReplicas: 2
    rayStartParams:
      num-gpus: 1
      num-cpus: 8
    containers:
    - name: ray
      image: rayproject/ray:latest-gpu
      resources:
        requests: {gpu: 1, cpu: 8, memory: 64Gi}
        limits: {gpu: 1, cpu: 16, memory: 128Gi}
    nodeSelector:
      server: "hpc"

  - groupName: gpu-workers-server3
    minReplicas: 4
    maxReplicas: 6
    rayStartParams:
      num-gpus: 1
      num-cpus: 4
    containers:
    - name: ray
      image: rayproject/ray:latest-gpu
      resources:
        requests: {gpu: 1, cpu: 4, memory: 16Gi}
        limits: {gpu: 1, cpu: 8, memory: 32Gi}
    nodeSelector:
      server: "serving"
```

**Usage Example (Distributed Training):**

```python
import ray
from ray.air import session
from ray.train import Trainer
from ray.air.config import RunConfig

ray.init(address="ray-head.ml-platform.svc.cluster.local:6379")

# Hyperparameter tuning with distributed training
trainer = Trainer(
    algorithm="ppo",
    config={
        "num_workers": 4,
        "num_gpus_per_worker": 0.5,  # Fractional GPU sharing
        "framework": "torch",
    },
    run_config=RunConfig(
        name="malaria-hpo",
        storage_path="s3://modellers/ray-experiments/",
    )
)

results = trainer.fit()

# Ray automatically schedules workers to available GPUs across Server 2 + 3
# If Server 3 GPUs at capacity, Server 2 GPUs used
# If Server 2 GPUs idle, used for inference overflow
```

---

### Phase 2 Deployment

**Infrastructure (Terraform additions):**

```hcl
# Server 2 k8s cluster setup
resource "kubernetes_cluster" "server2" {
  name = "hpc-cluster"
  # k8s version, networking, etc.
}

# Keycloak
helm_release.keycloak {}

# JupyterHub updates (from Phase 1)
helm_release.jupyterhub {
  # Updated values with OAuthenticator, pre_spawn_hook
}

# Slurm (system service, not Terraform)
# Manual setup via slurm.conf, slurmctld, slurmd

# MLflow
helm_release.mlflow {}

# Workspace Service
helm_release.workspace_service {}

# Ray Cluster
helm_release.ray_cluster {}
```

**Deployment Script additions:**

```bash
deploy/deploy-node.sh
├─ ... (Phase 1 steps 1-10)
├─ Step 11: Keycloak deployment + realm setup
├─ Step 12: JupyterHub migration + OAuthenticator config
├─ Step 13: MLflow deployment
├─ Step 14: Workspace Service deployment
├─ Step 15: Ray Cluster deployment
├─ Step 16: Slurm configuration (manual, pre-setup)
└─ Step 17: Integration verification
```

---

## Phase 3+: Model Serving & Analytics

### Components

#### 1. Harbor (Container Registry)

**Purpose:** Centralized Docker image registry for trained models.

**Deployment:** Bitnami Harbor Helm chart, Server 3 k8s, `harbor` namespace

**Architecture:**

```
Server 2: Model Registry Service
    ↓ (docker push)
Server 3: Harbor Registry
├─ Images: harbor.serving.dakar.local/models/{model-name}:{version}
├─ Vulnerability scanning: Trivy
├─ Access control: RBAC per project
└─ Replication policies: (optional, to cloud DR)
```

**Configuration (harbor-values.yaml):**

```yaml
harbor:
  externalURL: https://harbor.serving.dakar.local
  adminPassword: ${HARBOR_ADMIN_PASSWORD}
  secretKey: ${HARBOR_SECRET_KEY}

  persistence:
    enabled: true
    storageClass: local-path
    size: 500Gi

  expose:
    ingress:
      enabled: true
      hostname: harbor.serving.dakar.local
      tls: true

  trivy:
    enabled: true  # Scan images for CVEs

  notaryServer:
    enabled: true  # Image signing

  # Projects
  projects:
  - project_name: models
    is_public: false
```

**Image Naming Convention:**

```
harbor.serving.dakar.local/models/
├─ malaria-classifier:1.0.0
├─ malaria-classifier:1.0.1-staging
├─ sentiment-analysis:2.3.0
├─ risk-score-predictor:3.2.0-rc1
└─ (any model trained in the platform)
```

**Kubernetes ImagePullSecret:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-creds
  namespace: kserve
type: kubernetes.io/dockercfg
data:
  .dockercfg: |
    {
      "harbor.serving.dakar.local": {
        "auth": "base64(username:password)"
      }
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-sa
  namespace: kserve
imagePullSecrets:
- name: harbor-creds
```

---

#### 2. KServe (Model Serving)

**Purpose:** Serve trained models as REST/gRPC endpoints with auto-scaling and monitoring.

**Deployment:** KServe Helm chart, Server 3 k8s, `kserve` namespace

**Architecture:**

```
KServe Controller (Server 3)
├─ Watches InferenceService CRDs
├─ Creates predictor pods
├─ Manages canary deployments
└─ Scales based on metrics

InferenceService: malaria-classifier
├─ Predictor: SKLearn container
│  └─ Image: harbor.serving.dakar.local/models/malaria-classifier:1.0.0
│  └─ Replicas: 2-4 (auto-scale based on QPS)
│  └─ Resources: 1 GPU, 4 CPU, 16GB RAM per replica
├─ Explainer: (optional) SHAP or LIME
└─ Transformer: (optional) pre-processing logic

Endpoint: http://malaria-classifier.kserve.svc.cluster.local:8000/v1/models/malaria-classifier:predict
```

**InferenceService Example:**

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: malaria-classifier
  namespace: kserve
  labels:
    model-name: malaria-classifier
    model-version: 1.0.0
    trained-by: alice
spec:
  predictor:
    containers:
    - name: predictor
      image: harbor.serving.dakar.local/models/malaria-classifier:1.0.0
      ports:
      - containerPort: 8000
      env:
      - name: MODEL_PATH
        value: /mnt/models/model.pkl
      - name: MLFLOW_RUN_ID
        value: abc123def456
      resources:
        requests:
          cpu: 2
          memory: 8Gi
          nvidia.com/gpu: 1
        limits:
          cpu: 4
          memory: 16Gi
          nvidia.com/gpu: 1
      volumeMounts:
      - name: model-artifact
        mountPath: /mnt/models

  # Auto-scaling based on CPU/memory/throughput
  scaler:
    minReplicas: 1
    maxReplicas: 4
    metrics:
    - type: cpu
      value: 70  # Scale up if CPU > 70%
    - type: memory
      value: 80  # Scale up if memory > 80%
    - type: rps
      value: 100  # Scale up if requests/sec > 100

  # Canary deployment (gradual rollout)
  canary:
    trafficPercent: 10  # Route 10% to new version initially
    minReplicas: 1

  volumes:
  - name: model-artifact
    emptyDir: {}
    # Or mount from MinIO:
    # - name: model-artifact
    #   s3:
    #     bucket: modellers
    #     path: {user}/deployed-models/v1.0.0/
```

**Monitoring:**

```python
# Prometheus metrics exported by KServe
kserve_inferences_total{
    model_name="malaria-classifier",
    version="1.0.0",
    status="success"  # success, error, timeout
} = 1000000

kserve_inference_latency_seconds{
    model_name="malaria-classifier",
    version="1.0.0",
    quantile="0.99"
} = 0.150  # 150ms p99 latency

kserve_model_gpu_utilization_percent{
    model_name="malaria-classifier",
    replica="malaria-classifier-predictor-0"
} = 65

# Grafana dashboard: inference latency, error rate, GPU utilization
# AlertManager: alert if latency > 200ms or error rate > 5%
```

---

#### 3. Model Registry Service (Phase 3+)

**Purpose:** Automatically build Docker images from MLflow artifacts and push to Harbor.

**Deployment:** Custom FastAPI application, Server 2 k8s (not Server 3)

**Workflow:**

```
MLflow: User tags run with "stage=production-candidate"
    ↓
Model Registry Service (Server 2) detects tag
    ├─ Fetches artifact from S1 MinIO: s3://modellers/mlflow/runs/{run_id}/artifacts/model/
    ├─ Queries S1 PostgreSQL for training metadata
    ├─ Builds Dockerfile:
    │  FROM python:3.11-slim
    │  COPY model.pkl /app/model.pkl
    │  COPY inference.py /app/
    │  RUN pip install -r requirements.txt
    │  ENTRYPOINT ["python", "-m", "inference"]
    ├─ docker build → image
    ├─ docker push → harbor.serving.dakar.local/models/model-name:{version}
    ├─ Inserts model_versions row in S1 PostgreSQL
    └─ Inserts model_approvals row (status=pending)

Admin Dashboard (Server 3) shows pending approval
    ↓
Admin approves
    ↓
Model Approval Service (Server 3) creates KServe InferenceService
    ↓
KServe pulls image from Harbor
    ↓
Model serving live
```

**Configuration:**

```python
# model-registry-service/config.py
class Settings:
    mlflow_tracking_uri = "http://mlflow.hpc.dakar.local:5000"
    postgres_dsn = "postgresql://..."  # To Server 1
    minio_endpoint = "http://minio.data-stack.svc.cluster.local:9000"
    harbor_url = "https://harbor.serving.dakar.local"
    harbor_api_token = "${HARBOR_API_TOKEN}"  # From k8s secret
```

**API:**

```python
# POST /api/v1/models/register
# Called manually or via webhook when MLflow run is tagged
{
    "mlflow_run_id": "abc123",
    "mlflow_experiment_id": "0",
    "model_name": "malaria-classifier",
    "version": "1.0.0"
}

# Response
{
    "image_uri": "harbor.serving.dakar.local/models/malaria-classifier:1.0.0",
    "image_digest": "sha256:abc123...",
    "model_version_id": "uuid-xxx",
    "status": "registered",
    "lineage": {
        "training_job_id": "slurm-job-12345",
        "trained_by": "alice",
        "training_data_buckets": ["raw/health-data/2024-Q1/"],
        "code_version": "github.com/org/repo@commit-abc123",
        "metrics": {"accuracy": 0.942}
    }
}
```

---

#### 4. Model Approval Service (Phase 3+)

**Purpose:** Gate model deployments with formal approval workflow and audit trail.

**Deployment:** Custom FastAPI application, Server 3 k8s, `model-governance` namespace

**Workflow:**

```
1. Model Registry Service creates model_versions + model_approvals row (pending)
2. Admin Dashboard queries S1 PostgreSQL for pending approvals
3. Admin reviews: metrics, code version, data, training info
4. Admin clicks "APPROVE"
5. Model Approval Service:
   a. Updates model_approvals.status = 'approved'
   b. Creates KServe InferenceService
   c. Logs to admin_audit_log
   d. Waits for KServe rollout (status = ready)
6. KServe pod pulls image, starts serving
7. Predictions logged to inference_logs
```

**Approval Checklist (stored in PostgreSQL):**

```python
approval_checklist = {
    "metrics_acceptable": {
        "check": "Accuracy >= 93%",
        "result": True,
        "actual_value": "94.2%",
        "threshold": "93.0%"
    },
    "code_reviewed": {
        "check": "Code review completed",
        "result": True,
        "reviewer": "bob",
        "reviewed_at": "2026-04-27T..."
    },
    "data_documented": {
        "check": "Training data version documented",
        "result": True,
        "data_version": "raw/health-data/2024-Q1/",
        "record_count": 150000
    },
    "test_performance": {
        "check": "Performance on held-out test set acceptable",
        "result": True,
        "accuracy": "94.1%",
        "auc": "0.96"
    },
    "no_data_drift": {
        "check": "No data drift vs previous version",
        "result": True,
        "ks_statistic": 0.08
    }
}
```

**API:**

```python
# GET /admin/approvals
# Returns pending approvals for admin dashboard

# POST /admin/approvals/{approval_id}/approve
{
    "notes": "Validated on Q1 2024 data, clear improvement",
    "approval_checklist": {
        "metrics_acceptable": True,
        "code_reviewed": True,
        # ... all checks marked True
    }
}

# Response: Creates KServe InferenceService
{
    "inference_service_name": "malaria-classifier-prod",
    "status": "deploying",
    "created_at": "2026-04-27T..."
}

# GET /admin/approvals/{approval_id}/status
# Check deployment progress
{
    "status": "ready",
    "endpoint_url": "http://malaria-classifier-prod.kserve:8000/predict",
    "replicas_ready": 2,
    "replicas_total": 2
}

# POST /admin/deployments/{deployment_id}/rollback
{
    "reason": "Error rate spiked to 10%"
}
# Rolls back to previous model version
```

---

#### 5. Trino (SQL Query Engine)

**Purpose:** Query data across MinIO, PostgreSQL, and other sources using SQL.

**Deployment:** Bitnami Trino Helm chart, Server 3 k8s, `analytics` namespace

**Architecture:**

```
Trino Coordinator (Server 3)
├─ Accepts SQL queries
├─ Distributes across workers
├─ Manages connectors
└─ Web UI: http://trino.serving.dakar.local:8080

Trino Workers (Server 3)
├─ Execute query fragments
└─ Connect to data sources

Connectors:
├─ S3 (MinIO): query s3://raw/, s3://standard/, s3://modellers/
├─ PostgreSQL: query Server 1 PostgreSQL directly
├─ Iceberg: query via Iceberg connector (for versioned tables from Unity Catalog)
└─ Delta: query Delta lake tables (from Spark jobs)
```

**Configuration (trino-values.yaml):**

```yaml
trino:
  image: trinodb/trino:latest
  replicas: 3
  ingress:
    enabled: true
    hostname: trino.serving.dakar.local

  connectors:
    s3:
      hive.s3.endpoint: "http://minio.data-stack.svc.cluster.local:9000"
      hive.s3.access-key: ${MINIO_ACCESS_KEY}
      hive.s3.secret-key: ${MINIO_SECRET_KEY}
      hive.s3.path-style-access: "true"
      hive.s3.ssl: "false"

    postgresql:
      connection-url: "jdbc:postgresql://pgbouncer.data-stack.svc.cluster.local:5432/health_node"
      connection-user: "trino_user"
      connection-password: ${POSTGRES_TRINO_PASSWORD}

    iceberg:
      hive.metastore.uri: "thrift://..."  # Hive metastore (if Unity Catalog deployed)
```

**Example Queries:**

```sql
-- Query raw data in MinIO
SELECT
    patient_id,
    age,
    diagnosis,
    admission_date
FROM s3.default.raw_encounters
WHERE admission_date >= DATE '2024-01-01'
LIMIT 100;

-- Join MinIO data with PostgreSQL metadata
SELECT
    re.patient_id,
    re.diagnosis,
    wm.model_name,
    il.prediction_confidence
FROM s3.default.raw_encounters re
JOIN postgres.public.inference_logs il ON re.patient_id = il.patient_id
JOIN postgres.workspace.model_versions wm ON il.model_version_id = wm.id
WHERE re.admission_date >= DATE '2024-01-01'
  AND il.timestamp >= NOW() - INTERVAL '7 days';

-- Query versioned table from Unity Catalog
SELECT * FROM health_data.raw.encounters VERSION AS OF 2;
```

---

#### 6. FastAPI Endpoints (Custom Inference APIs)

**Purpose:** Wrapper around KServe models with business logic, response formatting, rate limiting.

**Deployment:** Custom FastAPI application, Server 3 k8s, `api` namespace

**Architecture:**

```
Client Application
    ↓ (HTTP POST /predict)
FastAPI Server (Server 3)
├─ Authentication (Keycloak token)
├─ Rate limiting (per user)
├─ Input validation
├─ Call KServe model
├─ Post-processing (format response, add metadata)
├─ Log to inference_logs (PostgreSQL)
└─ Return JSON response
```

**Example:**

```python
# fastapi-server/app.py
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
import requests
import json
from datetime import datetime

app = FastAPI()

class PredictionRequest(BaseModel):
    patient_age: int
    symptoms: List[str]
    medical_history: dict

class PredictionResponse(BaseModel):
    prediction: float  # 0-1 risk score
    confidence: float
    model_version: str
    explanation: str
    timestamp: datetime

@app.post("/api/v1/malaria-risk/predict", response_model=PredictionResponse)
async def predict_malaria_risk(
    request: PredictionRequest,
    user = Depends(get_current_user)
):
    # Rate limiting
    if not check_rate_limit(user.username, limit=100):
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    
    # Input validation
    if request.patient_age < 0 or request.patient_age > 120:
        raise HTTPException(status_code=400, detail="Invalid age")
    
    # Call KServe model
    kserve_response = requests.post(
        "http://malaria-classifier.kserve:8000/v1/models/malaria-classifier:predict",
        json={
            "instances": [[
                request.patient_age,
                len(request.symptoms),
                # ... feature engineering
            ]]
        },
        timeout=5
    )
    
    if kserve_response.status_code != 200:
        raise HTTPException(status_code=500, detail="Model inference failed")
    
    # Parse response
    model_output = kserve_response.json()
    prediction = model_output["predictions"][0][0]
    
    # Post-processing
    explanation = generate_explanation(request, prediction)
    
    # Log to PostgreSQL
    log_inference(
        user_id=user.username,
        model_name="malaria-classifier",
        input_features=request.dict(),
        prediction=prediction,
        timestamp=datetime.utcnow()
    )
    
    return PredictionResponse(
        prediction=prediction,
        confidence=model_output.get("confidence", 0.95),
        model_version="1.0.0",
        explanation=explanation,
        timestamp=datetime.utcnow()
    )
```

---

#### 7. MinIO Hot/Cold Storage Tiering

**Purpose:** Cost optimization for inference logs and historical data.

**Configuration (MinIO Lifecycle Policies):**

```json
{
  "Rules": [
    {
      "ID": "inference-logs-archival",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "logs/inference/"
      },
      "Transitions": [
        {
          "Days": 60,
          "StorageClass": "GLACIER"  // Move to AWS Glacier / GCS Archive
        }
      ],
      "Expiration": {
        "Days": 2555  // Keep for 7 years (compliance)
      }
    },
    {
      "ID": "old-model-artifacts",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "modellers/"
      },
      "NoncurrentVersionTransition": [
        {
          "NoncurrentDays": 180,
          "StorageClass": "GLACIER"
        }
      ]
    }
  ]
}
```

**Storage Tiers:**

| Tier | Duration | Storage Type | Cost | Use Case |
|------|----------|--------------|------|----------|
| **Hot** | 0-60 days | NVMe SSD (Server 1) | $0.10/GB/month | Real-time monitoring, drift detection, model evaluation |
| **Warm** | 60-180 days | Cloud object storage (Glacier) | $0.02/GB/month | Historical analysis (rare access) |
| **Cold** | 180+ days | Archive (Glacier Deep Archive) | $0.004/GB/month | Compliance, long-term audit trail |

**Retrieval:**

```python
# Query hot tier (fast)
SELECT * FROM inference_logs
WHERE timestamp >= NOW() - INTERVAL '60 days'
  AND model_version_id = model_id;

# Query cold tier (slow, requires restore)
# Step 1: Initiate restore from Glacier
aws s3api restore-object \
  --bucket minio-cold-tier \
  --key logs/inference/2023/predictions.parquet
# Wait 24 hours for restore

# Step 2: Query restored data
SELECT * FROM inference_logs_archived
WHERE timestamp >= '2023-01-01' AND timestamp <= '2023-01-31';
```

---

### Phase 3+ Deployment

**Infrastructure (Terraform additions):**

```hcl
# Server 3 k8s cluster setup
resource "kubernetes_cluster" "server3" {
  name = "serving-cluster"
  # k8s version, networking, etc.
}

# Harbor
helm_release.harbor {}

# KServe (already deployed in Phase 1 as optional)
helm_release.kserve {}

# Trino
helm_release.trino {}

# Model Registry Service
helm_release.model_registry_service {}

# Model Approval Service
helm_release.model_approval_service {}

# FastAPI Endpoints
helm_release.fastapi_endpoints {}

# MinIO tiering/archival (via MinIO admin API)
# (not Terraform, but CLI or admin interface)
```

---

## Complete Architecture

### Three-Server Network Topology

```
┌─────────────────────────────────────┐
│ Cloud Provider (Server 1 + 3)       │
│ VPC: 10.0.0.0/16                   │
│                                     │
│ ┌──────────────────────────────┐   │
│ │ SERVER 1: Datalake          │   │
│ │ Subnet: 10.0.1.0/24         │   │
│ │                              │   │
│ │ Services:                    │   │
│ │ ├─ MinIO                     │   │
│ │ ├─ PostgreSQL                │   │
│ │ ├─ Airflow                   │   │
│ │ ├─ Prometheus + Grafana      │   │
│ │ └─ (optional) Unity Catalog  │   │
│ │                              │   │
│ │ Hostname: datalake.dakar     │   │
│ └──────────────────────────────┘   │
│                                     │
│ ┌──────────────────────────────┐   │
│ │ SERVER 3: Model Serving      │   │
│ │ Subnet: 10.0.2.0/24          │   │
│ │                              │   │
│ │ Services:                    │   │
│ │ ├─ KServe                    │   │
│ │ ├─ Harbor                    │   │
│ │ ├─ Trino                     │   │
│ │ ├─ FastAPI Endpoints         │   │
│ │ └─ Model Approval Service    │   │
│ │                              │   │
│ │ Hostname: serving.dakar      │   │
│ └──────────────────────────────┘   │
│                                     │
│ NAT Gateway: outbound               │
│ Bastion Host: SSH access            │
└──────────────────┬──────────────────┘
                   │
        ┌──────────▼──────────┐
        │ VPN / ExpressRoute  │
        │ (TLS encrypted)     │
        └──────────┬──────────┘
                   │
┌──────────────────▼──────────────────┐
│ On-Premises (Server 2)              │
│ Network: 192.168.1.0/24             │
│                                     │
│ Services:                           │
│ ├─ Keycloak (auth)                  │
│ ├─ JupyterHub (notebooks)           │
│ ├─ Slurm (HPC scheduler)            │
│ ├─ MLflow (experiment tracking)     │
│ ├─ Ray Cluster (GPU pooling)        │
│ ├─ Unity Catalog (data governance)  │
│ └─ Workspace Service (project mgmt) │
│                                     │
│ Hardware:                           │
│ ├─ 2x Xeon 64c (128 cores)          │
│ ├─ 256GB RAM                        │
│ └─ 2 GPUs                           │
│                                     │
│ Hostname: hpc.dakar                 │
│ Firewall: only VPN ports open       │
└─────────────────────────────────────┘
```

### Inter-Service Communication

**Direct Connections:**

| Source | Destination | Protocol | Purpose | Auth |
|--------|-------------|----------|---------|------|
| JupyterHub | PostgreSQL (S1) | psycopg2 (SSL) | Workspace metadata | Password |
| JupyterHub | MinIO (S1) | S3 (TLS) | Read/write data | API key (per-user) |
| Slurm Job | MinIO (S1) | S3 (TLS) | Upload artifacts | API key |
| MLflow | PostgreSQL (S1) | psycopg2 (SSL) | Experiment metadata | Password |
| MLflow | MinIO (S1) | S3 (TLS) | Store artifacts | API key |
| Workspace Service | PostgreSQL (S1) | psycopg2 (SSL) | Workspace metadata | Password |
| Workspace Service | MinIO (S1) | S3 (TLS) | Create buckets, manage policies | Admin key |
| KServe | MinIO (S1) | S3 (TLS) | Read model artifacts | API key (read-only) |
| Model Registry | PostgreSQL (S1) | psycopg2 (SSL) | Log lineage | Password |
| Model Registry | MinIO (S1) | S3 (TLS) | Fetch artifacts | API key |
| Model Registry | Harbor (S3) | Docker API (TLS) | Push images | Token |
| Model Approval | PostgreSQL (S1) | psycopg2 (SSL) | Approvals, lineage | Password |
| Trino | MinIO (S1) | S3 (TLS) | Query data | API key |
| Trino | PostgreSQL (S1) | JDBC (SSL) | Query metadata | Password |
| FastAPI | KServe | HTTP | Call model | None (internal) |
| FastAPI | PostgreSQL (S1) | psycopg2 (SSL) | Log predictions | Password |

**Token-Based (Keycloak):**

| Client | Flow | Purpose |
|--------|------|---------|
| JupyterHub User | OAuth2 | Log in to JupyterHub |
| Workspace Service API | Token verification | Authorize API calls |
| KServe Admin | OAuth2 | Log in to admin dashboard |
| Airflow | OIDC | Log in to Airflow UI |
| Model Approval API | Service account | Create KServe InferenceServices |

---

## Data Models & Schemas

### PostgreSQL Schema (Server 1: health_node database)

#### Workspace Schema (Phase 2+)

```sql
CREATE SCHEMA IF NOT EXISTS workspace;

-- Workspaces: user projects
CREATE TABLE workspace.workspaces (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL,
    project_name TEXT NOT NULL,
    display_name TEXT,
    description TEXT,
    minio_prefix TEXT NOT NULL,  -- e.g., modellers/alice/malaria-classifier/
    status TEXT NOT NULL DEFAULT 'active',  -- active, archived, suspended
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (username, project_name)
);

-- MinIO per-user service accounts
CREATE TABLE workspace.minio_service_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    minio_access_key TEXT NOT NULL,      -- Access key ID
    iam_policy_name TEXT NOT NULL,       -- e.g., user-alice-policy
    k8s_secret_name TEXT NOT NULL,       -- minio-user-alice-creds
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- GitHub repo configurations per workspace
CREATE TABLE workspace.git_configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    username TEXT NOT NULL,
    repo_url TEXT NOT NULL,              -- https://github.com/org/repo.git
    branch TEXT NOT NULL DEFAULT 'main',
    credential_type TEXT NOT NULL DEFAULT 'https_token',  -- https_token, ssh_key, none
    k8s_secret_name TEXT,                -- git-creds-{username}
    clone_path TEXT,                     -- relative path under home
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Bucket access grants with approval workflow
CREATE TABLE workspace.bucket_access_grants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    username TEXT NOT NULL,
    bucket_name TEXT NOT NULL,
    path_prefix TEXT,                    -- NULL for bucket root
    access_level TEXT NOT NULL DEFAULT 'read',  -- read, readwrite
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, approved, denied, revoked
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at TIMESTAMPTZ,
    reviewed_by TEXT,
    review_notes TEXT,
    UNIQUE (workspace_id, bucket_name, path_prefix)
);

-- Notebook dependencies on resources
CREATE TABLE workspace.notebook_dependencies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id) ON DELETE CASCADE,
    notebook_path TEXT NOT NULL,        -- relative to home
    resource_type TEXT NOT NULL,        -- bucket, git_repo, model, experiment
    resource_ref TEXT NOT NULL,         -- bucket name, repo URL, model ID, etc.
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, notebook_path, resource_type, resource_ref)
);

-- Training jobs (Slurm, Spark, etc.)
CREATE TABLE workspace.training_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id),
    job_type TEXT NOT NULL,             -- slurm, spark, local
    job_id TEXT NOT NULL,               -- Slurm job ID or Spark app ID
    mlflow_run_id TEXT,                 -- link to MLflow
    submitted_by TEXT NOT NULL,
    submitted_at TIMESTAMPTZ DEFAULT now(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, running, succeeded, failed, cancelled
    exit_code INT,
    
    -- Resource tracking
    cpu_cores_allocated INT,
    gpu_count INT,
    gpu_type TEXT,                      -- A40, V100, A100, etc.
    memory_gb INT,
    wall_time_seconds INT,
    cost_usd FLOAT,
    
    -- Data lineage
    input_buckets TEXT[],               -- buckets read
    output_bucket TEXT,                 -- bucket where artifacts written
    code_git_commit TEXT,
    hyperparameters JSONB,
    metrics JSONB,
    
    -- Slurm-specific
    slurm_command TEXT,                 -- for reproducibility
    
    UNIQUE (job_type, job_id)
);

-- Model versions (post-training registration)
CREATE TABLE workspace.model_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID REFERENCES workspace.workspaces(id),
    training_job_id UUID REFERENCES workspace.training_jobs(id),
    model_name TEXT NOT NULL,
    version TEXT NOT NULL,              -- 1.0.0, 1.0.1-rc1, etc.
    mlflow_run_id TEXT NOT NULL,
    mlflow_artifact_uri TEXT NOT NULL,  -- s3://modellers/.../artifacts/model/
    
    -- Lineage
    code_version TEXT NOT NULL,         -- git commit hash
    code_repo TEXT,
    data_version TEXT NOT NULL,
    training_data_buckets TEXT[],       -- buckets used in training
    training_start_time TIMESTAMPTZ,
    training_end_time TIMESTAMPTZ,
    trained_by TEXT NOT NULL,
    training_script_path TEXT,
    
    -- Parameters & metrics
    hyperparameters JSONB,
    training_metrics JSONB,             -- loss, accuracy, auc, etc.
    evaluation_metrics JSONB,           -- test set metrics
    
    -- Container image
    container_image TEXT,               -- harbor.../models/model-name:v1.0.0
    container_digest TEXT,              -- SHA256
    
    -- Dependencies
    python_dependencies JSONB,          -- {"torch": "2.0.1", ...}
    system_dependencies TEXT[],
    
    description TEXT,
    tags TEXT[],                        -- ["production-ready", "approved", ...]
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by TEXT,
    
    UNIQUE (workspace_id, model_name, version)
);

-- Model approvals (formal gate to KServe)
CREATE TABLE workspace.model_approvals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id UUID NOT NULL REFERENCES workspace.model_versions(id),
    status TEXT NOT NULL DEFAULT 'pending',  -- pending, approved, rejected, revoked
    environment TEXT NOT NULL,         -- staging, production
    
    -- Request
    requested_by TEXT NOT NULL,
    requested_at TIMESTAMPTZ DEFAULT now(),
    request_reason TEXT,
    
    -- Approval
    approved_by TEXT,
    approved_at TIMESTAMPTZ,
    approval_notes TEXT,
    approval_checklist JSONB,          -- {"metrics_acceptable": true, ...}
    
    -- Revocation
    revoked_by TEXT,
    revoked_at TIMESTAMPTZ,
    revocation_reason TEXT,
    
    UNIQUE (model_version_id, environment)
);

-- Model deployments (KServe inference services)
CREATE TABLE workspace.model_deployments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id UUID NOT NULL REFERENCES workspace.model_versions(id),
    approval_id UUID NOT NULL REFERENCES workspace.model_approvals(id),
    
    inference_service_name TEXT NOT NULL,  -- malaria-classifier
    environment TEXT NOT NULL,             -- staging, production
    namespace TEXT DEFAULT 'kserve',
    
    -- Deployment tracking
    deployed_at TIMESTAMPTZ DEFAULT now(),
    deployed_by TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'deploying',  -- deploying, ready, failed, serving
    status_message TEXT,
    
    -- KServe serving details
    endpoint_url TEXT,
    canary_traffic_percent INT DEFAULT 0,
    
    -- Rollback
    rollback_from_version_id UUID REFERENCES workspace.model_versions(id),
    rollback_reason TEXT,
    rollback_at TIMESTAMPTZ,
    
    -- Performance
    average_latency_ms FLOAT,
    p99_latency_ms FLOAT,
    error_rate_percent FLOAT,
    requests_per_minute INT,
    
    created_at TIMESTAMPTZ DEFAULT now(),
    
    UNIQUE (inference_service_name, environment)
);

-- Inference logs (predictions made)
CREATE TABLE workspace.inference_logs (
    id BIGSERIAL PRIMARY KEY,
    deployment_id UUID REFERENCES workspace.model_deployments(id),
    
    timestamp TIMESTAMPTZ DEFAULT now(),
    request_id TEXT,
    
    -- Input/output
    input_features JSONB,
    prediction JSONB,
    prediction_confidence FLOAT,
    actual_label JSONB,                 -- ground truth (logged later)
    
    -- Timing
    inference_latency_ms FLOAT,
    
    -- Model version
    model_version_id UUID REFERENCES workspace.model_versions(id),
    
    -- Cost tracking
    gpu_utilization_percent FLOAT,
    memory_usage_mb INT
);

-- Admin audit log
CREATE TABLE workspace.admin_audit_log (
    id BIGSERIAL PRIMARY KEY,
    actor TEXT NOT NULL,                -- username of admin
    action TEXT NOT NULL,               -- create_workspace, approve_model, etc.
    target_type TEXT,                   -- workspace, model, bucket_grant, etc.
    target_id TEXT,
    detail JSONB,
    cluster TEXT,                       -- datalake, hpc, serving
    request_id TEXT,
    cost_impact_usd FLOAT,
    acted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Slurm quotas per user
CREATE TABLE workspace.slurm_quotas (
    username TEXT PRIMARY KEY,
    gpu_hours_limit INT,               -- e.g., 100
    gpu_hours_used INT DEFAULT 0,
    cpu_core_hours_limit INT,          -- e.g., 1000
    cpu_core_hours_used INT DEFAULT 0,
    quota_reset_date DATE
);

-- Unity Catalog lineage (if using UC)
CREATE TABLE workspace.unity_catalog_lineage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_table TEXT,                 -- catalog.schema.table
    source_version INT,
    destination_type TEXT,             -- model, report, table
    destination_id UUID,
    recorded_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX idx_workspaces_username ON workspace.workspaces(username);
CREATE INDEX idx_bucket_access_grants_status ON workspace.bucket_access_grants(status);
CREATE INDEX idx_bucket_access_grants_workspace ON workspace.bucket_access_grants(workspace_id);
CREATE INDEX idx_training_jobs_workspace ON workspace.training_jobs(workspace_id, status);
CREATE INDEX idx_training_jobs_submitted ON workspace.training_jobs(submitted_by, submitted_at DESC);
CREATE INDEX idx_model_versions_name ON workspace.model_versions(model_name, created_at DESC);
CREATE INDEX idx_model_approvals_status ON workspace.model_approvals(status, created_at DESC);
CREATE INDEX idx_model_deployments_environment ON workspace.model_deployments(environment, status);
CREATE INDEX idx_inference_logs_deployment ON workspace.inference_logs(deployment_id, timestamp DESC);
CREATE INDEX idx_inference_logs_timestamp ON workspace.inference_logs(timestamp DESC);
CREATE INDEX idx_admin_audit_log_acted ON workspace.admin_audit_log(acted_at DESC);
```

---

## API Specifications

[Due to length, API specifications are documented in separate file: API_SPECIFICATIONS.md]

---

## Deployment Architecture

### Kubernetes Namespaces

```
kube-system/
  ├─ kube-dns, coredns
  ├─ kube-proxy
  └─ kube-controller-manager

cert-manager/
  ├─ cert-manager (TLS certificates)
  └─ ClusterIssuer for Let's Encrypt

ingress-basic/
  └─ nginx-ingress-controller

data-stack/  (Server 1 + 2 shared namespace)
  ├─ MinIO
  ├─ PostgreSQL + PgBouncer
  ├─ Airflow
  ├─ JupyterHub
  ├─ Workspace Service
  └─ MLflow

keycloak/  (Server 2)
  └─ Keycloak

monitoring/  (Server 1)
  ├─ Prometheus
  ├─ Grafana
  ├─ AlertManager
  └─ Node Exporter

kserve/  (Server 3)
  └─ KServe Controller
  └─ KServe InferenceServices

harbor/  (Server 3)
  └─ Harbor

ml-platform/  (Server 2)
  ├─ Ray Cluster Head + Workers
  └─ Model Registry Service

model-governance/  (Server 3)
  └─ Model Approval Service

analytics/  (Server 3)
  ├─ Trino
  └─ Metadata database (if needed)

api/  (Server 3)
  └─ FastAPI Endpoints
```

---

## Security Model

### Authentication & Authorization

**Phase 1:**
- DummyAuthenticator (shared password, insecure, testing only)
- MinIO root credentials (shared across platform, minimized)

**Phase 2 Upgrade:**
- Keycloak (centralized identity)
- OIDC/OAuth2 for all services
- Role-based access control (data-scientist, data-engineer, model-reviewer, infrastructure-admin)

**Phase 3:**
- Keycloak (existing)
- Service accounts for cross-service authentication (JWT tokens)
- API keys for programmatic access (workspace-service, model-registry)

### Data Access Control

**Layer 1: Storage (MinIO IAM)**
- Per-user service accounts with scoped policies
- Bucket-level and path-level access control
- Read-only access for public datasets
- Read-write for user workspaces

**Layer 2: Database (PostgreSQL RBAC)**
- Keycloak roles mapped to PostgreSQL roles
- Row-level security for sensitive data
- Audit logs for all DDL/DML

**Layer 3: API (FastAPI + Keycloak)**
- Token validation on every request
- Role-based endpoint authorization
- Request rate limiting per user/IP

**Layer 4: Compute (Kubernetes RBAC)**
- ServiceAccounts per component
- Minimal privilege (least privilege principle)
- Network policies for pod-to-pod communication

### Secret Management

**Credentials Storage:**
- Kubernetes Secrets (in-cluster):
  - Keycloak credentials
  - MinIO admin key
  - PostgreSQL password
  - Harbor API token
  - Service account tokens
- Encrypted at rest (enable Kubernetes secret encryption)
- Rotated annually (or on compromise)

**Best Practices:**
- Never commit secrets to git (.gitignore)
- Use separate secrets for dev/staging/prod
- Audit log all secret access
- Consider external secret store (HashiCorp Vault) for production

### Network Security

**Firewall Rules:**
- Datalake (Server 1): Public internet only for HTTPS API, SSH bastion
- HPC (Server 2): Isolated on-prem network, VPN tunnel only
- Serving (Server 3): Cloud VPC, security groups restrict to needed ports

**TLS/SSL:**
- All inter-service communication: TLS 1.3
- Self-signed certificates or Let's Encrypt via cert-manager
- Certificate rotation: automatic (cert-manager)

**VPN Tunnel (Server 2 ↔ Server 1/3):**
- WireGuard or OpenVPN
- Key exchange via secure out-of-band channel
- Regular key rotation (quarterly)

---

## Operations & Monitoring

### Prometheus Metrics

[Extensive metrics defined in OPERATIONS_GUIDE.md]

**Key Dashboards:**
1. Cluster Health (CPU, memory, disk)
2. MinIO (storage usage, API latency)
3. PostgreSQL (connections, query latency, replication lag)
4. Airflow (DAG success/failure, task duration)
5. JupyterHub (active users, notebook resource usage)
6. KServe (inference latency, throughput, error rate)
7. Cost Breakdown (training cost/user, inference cost/model)
8. Lineage & Governance (data lineage, model approvals, audit logs)

### Alerting Rules

[Extensive alerting rules defined in OPERATIONS_GUIDE.md]

**Critical Alerts:**
- PostgreSQL down or high query latency
- MinIO storage approaching capacity
- KServe model error rate > 5%
- Inference latency p99 > 200ms
- Failed data pipeline (Airflow DAG failure)

---

## Migration Paths

### Phase 1 → Phase 2

**Prerequisites:**
- Server 2 hardware provisioned (2x Xeon, 256GB RAM, 2 GPUs)
- Network connectivity (VPN tunnel established)
- Keycloak instance running

**Steps:**
1. Deploy Keycloak on Server 2
2. Create realm, clients, roles, users
3. Deploy JupyterHub on Server 2 with OAuthenticator
4. Configure JupyterHub pre_spawn_hook
5. Migrate user data from Phase 1 JupyterHub (if running there):
   - Export user PVCs
   - Import into Server 2 storage
6. Deploy MLflow (Server 2)
7. Deploy Workspace Service
8. Test with small user cohort
9. Full migration (decommission Phase 1 JupyterHub if separate)

### Phase 2 → Phase 3

**Prerequisites:**
- Server 3 hardware provisioned (16+ cores, 4-6 GPUs)
- Network connectivity (cloud VPC or VPN)
- Harbor instance running

**Steps:**
1. Deploy KServe on Server 3
2. Deploy Model Registry Service on Server 2
3. Deploy Model Approval Service on Server 3
4. Deploy Trino on Server 3
5. Deploy FastAPI endpoints
6. Test model deployment pipeline with staging models
7. Configure MinIO lifecycle policies for hot/cold tiering
8. Monitor inference logs in production

---

## Appendices

### A. Glossary

- **OIDC:** OpenID Connect, OAuth2-based identity protocol
- **JWT:** JSON Web Token, stateless credential for API auth
- **SCRAM:** Salted Challenge Response Authentication Mechanism (PostgreSQL auth)
- **IAM:** Identity & Access Management (MinIO policies)
- **QoS:** Quality of Service (Slurm partition limits)
- **Lineage:** Tracking of data origin through transformation, training, and serving
- **Medallion Architecture:** Data organization (bronze → silver → gold) by quality
- **Drift Detection:** Monitoring for changes in data distribution (ML)
- **Canary Deployment:** Gradual rollout of new model version to subset of traffic
- **Tiering:** Moving data across storage layers (hot → cold)

### B. Reference Architectures

#### Minimal Setup (Single Server, Dev/Test)
- One k3s cluster with all components
- DummyAuthenticator (testing only)
- No Slurm, no GPU pooling
- MinIO on local storage
- PostgreSQL single node
- Good for: prototyping, testing

#### Three-Server Production (This Document)
- Server 1 (Cloud): Datalake
- Server 2 (On-Prem): HPC + ML Dev
- Server 3 (Cloud): Model Serving
- Keycloak, formal approval workflows, cost tracking
- Good for: production health AI platform

#### Multi-Region HA (Phase 4+, Not Covered Here)
- Multiple regions, active-active
- Cross-region data replication
- Failover automation
- Global load balancing
- Good for: enterprise, global deployments

### C. Deployment Checklist

**Pre-Deployment:**
- [ ] Provision hardware (CPU, GPU, storage)
- [ ] Network connectivity (VPN, firewall rules)
- [ ] Kubernetes clusters installed (k3s or k8s)
- [ ] Container images pre-built (custom postgres, jupyter, workspace-service)
- [ ] Secrets generated (passwords, API keys)
- [ ] DNS records configured (datalake.dakar, hpc.dakar, serving.dakar, auth.dakar, etc.)
- [ ] TLS certificates ready (self-signed or Let's Encrypt)

**Deployment Order:**
1. Server 1: MinIO, PostgreSQL, PgBouncer, Airflow, Prometheus, Grafana
2. Server 1: Ingress, cert-manager, AlertManager
3. Server 2: Keycloak
4. Server 2: JupyterHub (with OAuthenticator)
5. Server 2: Slurm (system service)
6. Server 2: MLflow, Workspace Service, Ray Cluster
7. Server 3: KServe, Harbor
8. Server 3: Trino, Model Registry, Model Approval, FastAPI
9. Validation: Run tests/validate-node.sh across all servers

**Post-Deployment:**
- [ ] All pods running (kubectl get pods -A)
- [ ] Services accessible (curl endpoints)
- [ ] Keycloak realm + clients configured
- [ ] First user sign-in successful
- [ ] MinIO buckets created (raw, standard, published, modellers)
- [ ] Airflow DAG scheduled and running
- [ ] Prometheus scraping all targets
- [ ] Grafana dashboards visible
- [ ] Backup strategy tested (PostgreSQL, MinIO)
- [ ] Monitoring alerts triggered and routed

---

**End of Technical Design Document (Phase 1, 2, 3+)**

This document covers all aspects of the three-server, three-phase platform. Refer to supplementary documents for:
- `API_SPECIFICATIONS.md` - Detailed API endpoints
- `OPERATIONS_GUIDE.md` - Runbooks, troubleshooting, monitoring
- `TASK_LIST.md` - Granular implementation tasks

