# Comprehensive Task List
## Public Health AI Infrastructure Platform

**Organization:** By component/service and phase (no timeline sequencing)  
**Status:** Task list for implementation planning

---

## Table of Contents

1. [Phase 1: Data Lakehouse Tasks](#phase-1-data-lakehouse-tasks)
2. [Phase 2: HPC & ML Development Tasks](#phase-2-hpc--ml-development-tasks)
3. [Phase 3+: Model Serving & Analytics Tasks](#phase-3-model-serving--analytics-tasks)
4. [Cross-Cutting Tasks](#cross-cutting-tasks)
5. [Integration & Validation Tasks](#integration--validation-tasks)

---

## Phase 1: Data Lakehouse Tasks

### MinIO Setup & Configuration

- [ ] **Provision MinIO storage infrastructure**
  - Select hardware/cloud instance for MinIO (single node or HA)
  - Configure storage backend (local disk, cloud object storage, NAS)
  - Size: minimum 1TB, recommend 2-5TB for growing data lake

- [ ] **Create MinIO Helm chart deployment**
  - Write `terraform/main.tf` MinIO helm_release block
  - Configure Bitnami MinIO chart values (version 11.x+)
  - Set root credentials (generate random, store in Kubernetes secret)
  - Disable deprecated Bitnami console sub-chart (use built-in MinIO MINIO_BROWSER)

- [ ] **Configure MinIO persistence**
  - Set up PVC with local-path storage class (or cloud block storage)
  - Size: `var.minio_persistence_size` (default 250Gi, adjustable)
  - Test backup/restore of MinIO data

- [ ] **Create MinIO buckets (Phase 1 only)**
  - Implement `deploy/deploy-node.sh` Step 3: bucket creation via `mc mb`
  - Buckets: raw, standard, published
  - Set bucket versioning (enabled) for data recovery
  - Configure lifecycle policies (Phase 3: hot/cold tiering)

- [ ] **Set up MinIO access control (IAM policies)**
  - Create MinIO root account credentials (stored in k8s secret `minio-creds`)
  - Write policy for shared Airflow access (read raw/, write standard/ + published/)
  - Test MinIO admin API access

- [ ] **Configure MinIO API ingress**
  - Create nginx ingress for MinIO S3 API (port 9000)
  - Hostname: `minio.dakar-datasphere-node.local`
  - Configure TLS (self-signed or cert-manager)
  - Test S3 connectivity: `aws s3 ls s3://raw --endpoint-url http://minio:9000`

- [ ] **Configure MinIO console ingress**
  - Create nginx ingress for MinIO console (port 9001)
  - Hostname: `console.dakar-datasphere-node.local`
  - Test web login: admin user + password from Kubernetes secret

- [ ] **Document MinIO operational procedures**
  - Write runbook: troubleshooting MinIO pod crashes
  - Write runbook: scaling MinIO storage
  - Write runbook: manual data backup/restore
  - Write runbook: user credential rotation

---

### PostgreSQL Setup & Configuration

- [ ] **Provision PostgreSQL storage**
  - Create PVC for PostgreSQL data (50Gi initial, scalable)
  - Configure local-path storage class
  - Test disk performance (IOPs, latency)

- [ ] **Build custom PostgreSQL image**
  - Create `docker/postgres-health-ext/Dockerfile`
  - Base: postgres:16-bullseye
  - Install PostGIS extension (with GDAL, PROJ dependencies)
  - Install pgvector extension (ML embeddings support)
  - Tag: `postgres-health-ext:16`
  - Push to local container registry or k3s containerd

- [ ] **Deploy PostgreSQL StatefulSet**
  - Write Kubernetes StatefulSet manifest (not Helm chart, due to custom image)
  - Configure: 1 replica, 5432 port, PVC attachment
  - Set resources: requests (cpu: 1, memory: 8Gi), limits (cpu: 4, memory: 32Gi)
  - Configure init script to create database + schema + extensions

- [ ] **Create PostgreSQL database and schema**
  - Create database `health_node` (via init job or manual)
  - Create user `postgres` (superuser, for migrations)
  - Create user `health_app` (app user, limited privileges)
  - Enable extensions: postgis, pgvector, pg_trgm
  - Test: connect via psql, verify extensions installed

- [ ] **Deploy PgBouncer connection pooling**
  - Create Kubernetes Deployment (2 replicas) for PgBouncer
  - Configure transaction mode (for Airflow compatibility)
  - Set pool size: 40 backend, 10 reserve, 500 max client connections
  - Configure SCRAM-SHA-256 authentication
  - Expose ClusterIP Service on port 5432

- [ ] **Create PostgreSQL Kubernetes secret**
  - Store superuser password in `postgres-creds` secret
  - Store app user password in same secret (key: app-password)
  - Reference in Terraform for Airflow + other services

- [ ] **Test PostgreSQL connectivity**
  - Connect from outside cluster: `psql -h datalake.dakar -U health_app -d health_node`
  - Connect via PgBouncer: `psql -h pgbouncer.data-stack.svc.cluster.local -U health_app -d health_node`
  - Verify SSL/TLS encryption for external connections

- [ ] **Set up PostgreSQL backup strategy**
  - Create Kubernetes CronJob for daily pg_dump
  - Store backups in PVC (20Gi `postgres-backups`)
  - Schedule: 02:00 UTC daily (off-peak)
  - Retention: 7 days (via cleanup script)
  - Test restore: pg_restore from backup

- [ ] **Configure PostgreSQL monitoring**
  - Expose PostgreSQL metrics to Prometheus (via postgres_exporter)
  - Metrics: connections, query latency, replication lag, cache hit ratio

- [ ] **Document PostgreSQL operational procedures**
  - Write runbook: troubleshooting slow queries
  - Write runbook: restoring from backup
  - Write runbook: scaling storage
  - Write runbook: user permission management

---

### Airflow Deployment & Configuration

- [ ] **Deploy Airflow Helm chart**
  - Add `apache-airflow/airflow` to Terraform helm_release
  - Configure: executor=KubernetesExecutor (one pod per task)
  - Database: PostgreSQL (Server 1)
  - Webserver replicas: 1
  - Scheduler replicas: 1

- [ ] **Configure Airflow authentication**
  - Set admin user + password (from Kubernetes secret)
  - Configure RBAC roles (viewer, user, op, admin)
  - (Phase 2: upgrade to Keycloak OIDC)

- [ ] **Create base data ingestion DAG**
  - File: `dags/daily_encounter_etl.py`
  - Tasks:
    1. Download raw data from external source (API, SFTP, etc.)
    2. Validate schemas + row counts
    3. Deduplicate + normalize
    4. Upload to MinIO `s3://raw/health-data/{date}/`
  - Schedule: daily at 00:00 UTC
  - Error handling: retry 3x, alert on failure

- [ ] **Create data validation DAG**
  - File: `dags/validate_raw_data.py`
  - Tasks: null checks, type checks, range checks, referential integrity
  - Runs after ingestion DAG
  - Publishes metrics to Prometheus

- [ ] **Create feature engineering DAG**
  - File: `dags/feature_engineering.py`
  - Read from `s3://raw/`
  - Perform transformations (aggregate, normalize, encode)
  - Write to `s3://standard/`
  - Schedule: weekly (after ingestion catches up)

- [ ] **Set up Airflow variables + connections**
  - MinIO connection: `s3://raw/` endpoint, credentials
  - Slack connection: for alerts (if available)
  - External data source connection: (API key, URL, auth method)

- [ ] **Configure Airflow logging**
  - Set log level: INFO (or DEBUG for development)
  - Log storage: local (or cloud object storage for production)
  - Rotate logs: 7 days retention

- [ ] **Configure Airflow alerting**
  - On DAG/task failure: send alert (email, Slack, webhook)
  - Template: DAG name, task name, error message, link to logs

- [ ] **Create Airflow ingress**
  - Hostname: `airflow.dakar-datasphere-node.local`
  - Configure TLS
  - Test login + DAG visibility

- [ ] **Document Airflow operational procedures**
  - Write runbook: triggering DAG manually
  - Write runbook: monitoring DAG execution
  - Write runbook: troubleshooting task failures
  - Write runbook: scaling Airflow for concurrent tasks

---

### Monitoring Stack (Prometheus + Grafana)

- [ ] **Deploy Prometheus Helm chart**
  - Add `kube-prometheus-stack/kube-prometheus-stack` to Terraform
  - Configure scrape targets: MinIO, PostgreSQL, Airflow, Kubernetes
  - Set retention: 30 days (configurable)
  - Storage: PVC (50Gi for 30-day retention)

- [ ] **Configure Prometheus scrape jobs**
  - kubernetes: scrape kubelet, kube-apiserver, kube-state-metrics
  - node: node-exporter (CPU, memory, disk, network)
  - minio: MinIO metrics endpoint (port 9000)
  - postgres: postgres_exporter (connections, query stats)
  - airflow: airflow metrics (DAG runs, task duration)

- [ ] **Deploy AlertManager**
  - Configure Slack/email receivers (if available)
  - Define alert routing (critical → PagerDuty, warning → Slack, info → log)
  - Test alert firing

- [ ] **Create Grafana dashboards (Phase 1)**
  - Dashboard 1: Kubernetes cluster health
    - Node CPU, memory, disk, network
    - Pod resource usage (top 10)
  - Dashboard 2: MinIO health
    - Storage usage, API latency, requests/sec
    - Disk I/O, network throughput
  - Dashboard 3: PostgreSQL health
    - Connections (active, idle, max)
    - Query latency (p50, p95, p99)
    - Cache hit ratio, replication lag
  - Dashboard 4: Airflow DAGs
    - DAG success/failure rate
    - Task duration (average, max)
    - Scheduling lag

- [ ] **Configure Grafana authentication**
  - Admin user: `admin` (password from Kubernetes secret)
  - RBAC: Viewer role for Airflow team
  - (Phase 2: upgrade to Keycloak OIDC)

- [ ] **Create Grafana ingress**
  - Hostname: `grafana.dakar-datasphere-node.local`
  - Configure TLS
  - Test login + dashboard access

- [ ] **Define critical alerting rules**
  - PostgreSQL down or unreachable
  - MinIO storage at 90% capacity
  - Airflow DAG failure (any DAG)
  - Node disk at 85% capacity
  - Kubernetes API unreachable

- [ ] **Document monitoring & alerting procedures**
  - Write runbook: acknowledging alerts in AlertManager
  - Write runbook: silencing noisy alerts
  - Write runbook: adding new Prometheus scrape job
  - Write runbook: interpreting dashboard metrics

---

### Terraform & IaC (Phase 1)

- [ ] **Create Terraform project structure**
  - Files: providers.tf, variables.tf, main.tf, outputs.tf
  - Variables file: kubeconfig_path, namespace, domain, passwords
  - Example values file: terraform.tfvars.example (no secrets committed)

- [ ] **Write Terraform providers configuration**
  - Kubernetes provider: config_path = var.kubeconfig_path
  - Helm provider: configured with kubernetes provider
  - Null provider: for null_resource tasks

- [ ] **Write Terraform variables**
  - kubeconfig_path, namespace, domain
  - MinIO: root_user, root_password, persistence_size, image_tag
  - PostgreSQL: superuser_password, app_password, persistence_size
  - Airflow: admin_password, fernet_key, webserver_secret_key
  - Monitoring: admin_password
  - cert-manager: version
  - kserve: version

- [ ] **Write Terraform main.tf**
  - Helm releases: MinIO, PostgreSQL, Airflow, Prometheus, Grafana, AlertManager, cert-manager, KServe (prepared)
  - Kubernetes resources: StatefulSet (PostgreSQL), Deployment (PgBouncer), Services, Ingresses, Secrets, ConfigMaps
  - Namespaces: data-stack, monitoring, ingress-basic, kserve (prepared)
  - Network policies: (if needed for security)

- [ ] **Write Terraform outputs**
  - Service endpoints: MinIO, PostgreSQL, Airflow, Grafana
  - Ingress URLs: minio.dakar, airflow.dakar, grafana.dakar
  - Kubernetes info: cluster name, namespace

- [ ] **Validate Terraform configuration**
  - `terraform validate`
  - `terraform plan`
  - Review for syntax errors, security issues, missing variables

- [ ] **Create Terraform module for Helm releases**
  - (Optional, but recommended for maintainability)
  - Module: helm_release with consistent variable naming

- [ ] **Store terraform state securely**
  - Local state file: .tfstate (add to .gitignore, never commit)
  - (Phase 2+: consider remote state backend: S3, GCS, Terraform Cloud)

---

### Deployment Script (Phase 1)

- [ ] **Create deploy/deploy-node.sh script**
  - Step 1: Check kubeconfig + kubectl access
  - Step 2: Create namespaces
  - Step 3: MinIO deployment + bucket creation
  - Step 4: PostgreSQL deployment + init
  - Step 5: Airflow deployment
  - Step 6: Prometheus + Grafana deployment
  - Step 7: cert-manager deployment
  - Step 8: ingress-nginx deployment
  - Step 9: KServe CRDs (prepared for Phase 3)
  - Step 10: Service ingresses
  - Validation: Call tests/validate-node.sh

- [ ] **Create deploy/setup-secrets.sh script**
  - Generate random passwords (if not provided)
  - Create Kubernetes secrets: minio-creds, postgres-creds, airflow-secrets, monitoring-secrets
  - Use `kubectl create secret --dry-run=client` pattern (idempotent)

- [ ] **Create deploy/bootstrap.sh script**
  - Prepare host: install kubectl, helm, yq, docker
  - Download kubeconfig from cloud provider (if needed)
  - Configure /etc/hosts with local DNS entries (minio.dakar, airflow.dakar, etc.)
  - Create kubeconfig backup

- [ ] **Write deploy/config/env-config.yaml**
  - Centralized configuration (domain, namespace, service hostnames)
  - Read by deploy scripts via `yq`
  - Variables: global.domain, global.namespace, minio.hostname, postgres.*, airflow.*, monitoring.*, kserve.*

- [ ] **Implement deployment validation**
  - File: tests/validate-node.sh
  - Check: all pods running, services accessible, ingresses responding
  - Health checks: curl endpoints, basic smoke tests
  - Success criteria: all steps pass, output formatted

---

### Documentation (Phase 1)

- [ ] **Create README.md**
  - Overview of platform
  - Phase 1 setup instructions
  - Prerequisites (kubeconfig, domain, hardware)
  - Quick start: `./deploy/bootstrap.sh && terraform apply && ./deploy/deploy-node.sh`
  - Troubleshooting section

- [ ] **Create DEPLOYMENT_GUIDE.md**
  - Detailed setup instructions
  - Terraform workflow (init, validate, plan, apply, destroy)
  - Deploy script breakdown (each step explained)
  - Secrets management
  - Backup/restore procedures
  - Upgrade procedures (k8s, Helm charts)

- [ ] **Create OPERATIONS_GUIDE.md**
  - Runbooks for common tasks
  - Troubleshooting procedures
  - Monitoring setup
  - Alert response guide
  - Incident response procedures
  - Capacity planning

- [ ] **Create ARCHITECTURE.md**
  - High-level overview of three-server design
  - Component diagrams
  - Data flow diagrams
  - Network topology
  - Security model (Phase 1 limitations noted)

---

## Phase 2: HPC & ML Development Tasks

### Keycloak Identity Management

- [ ] **Provision Keycloak infrastructure**
  - Provision Server 2 hardware (2x Xeon 64c, 256GB RAM, 2 GPUs)
  - Set up networking (VPN tunnel to Server 1)
  - Provision k8s cluster (k8s 1.26+, not k3s)

- [ ] **Deploy Keycloak Helm chart**
  - Add `keycloak/keycloak` to Terraform (Server 2)
  - Bitnami chart version 15.x+
  - Configure: PostgreSQL backend (Server 1 health_node database, separate schema)
  - Replicas: 1 (HA: 3 in production)
  - Resources: requests (cpu: 500m, memory: 1Gi), limits (cpu: 1, memory: 2Gi)

- [ ] **Configure Keycloak realm**
  - Realm name: `dakar-health`
  - Authentication flow: Standard (username/password)
  - (Optional) LDAP federation: point to AD/LDAP if available

- [ ] **Create Keycloak clients**
  - Client: jupyterhub
    - Client ID: jupyterhub
    - Access Type: public (web flow)
    - Redirect URIs: `https://hpc.dakar.local/hub/oauth_callback`
    - Scopes: openid, profile, email
  - Client: airflow
    - Client ID: airflow-oidc
    - Access Type: confidential (backend flow)
    - Redirect URIs: `https://datalake.dakar.local/airflow/login/generic/callback`
  - Client: kserve-admin (Phase 3)
    - Client ID: kserve-admin
    - Redirect URIs: `https://serving.dakar.local/admin/callback`
  - Client: model-approval-api (Phase 3)
    - Client ID: model-approval-api
    - Access Type: service-account

- [ ] **Create Keycloak roles**
  - data-scientist (can create workspaces, submit jobs, request bucket access)
  - data-engineer (+ modify data catalog, Airflow DAGs)
  - model-reviewer (+ approve models for deployment)
  - infrastructure-admin (full access)
  - unity-catalog-admin (manage Unity Catalog)

- [ ] **Create Keycloak user attributes**
  - cost_center (for billing, string)
  - team (ml-platform, data-infra, etc., list)
  - approved_gpu_hours (monthly quota, integer)
  - data_access_level (minimal, standard, elevated, select)

- [ ] **Create Keycloak users (test accounts)**
  - alice (data-scientist, test user)
  - bob (data-engineer, test user)
  - charlie (model-reviewer, test user)
  - admin (infrastructure-admin, platform admin)

- [ ] **Configure Keycloak ingress**
  - Hostname: `auth.hpc.dakar.local`
  - TLS: enabled (self-signed or cert-manager)
  - Test: curl `https://auth.hpc.dakar.local/realms/dakar-health/.well-known/openid-configuration`

- [ ] **Create Keycloak Kubernetes secret**
  - Secret: `keycloak-client-secrets`
  - Keys: jupyterhub-client-secret, airflow-client-secret, kserve-client-secret, model-approval-api-secret

- [ ] **Document Keycloak operational procedures**
  - Write runbook: creating new users
  - Write runbook: managing roles + permissions
  - Write runbook: resetting user passwords
  - Write runbook: enabling MFA (TOTP)

---

### JupyterHub Migration & Updates (Phase 2)

- [ ] **Migrate JupyterHub from Server 1 to Server 2**
  - Export existing user PVCs (if Phase 1 JupyterHub running)
  - Import into Server 2 storage
  - Update helm values: OAuthenticator instead of DummyAuthenticator

- [ ] **Update jupyterhub-values.yaml**
  - Authenticator: GenericOAuthenticator (Keycloak)
  - Configure OAuth endpoints: authorize_url, token_url, userdata_url
  - Add hub.extraConfig with pre_spawn_hook (workspace-service integration)
  - Remove DummyAuthenticator section

- [ ] **Implement JupyterHub pre_spawn_hook**
  - Python function in hub.extraConfig
  - Calls workspace-service `/spawn-config` endpoint
  - Mounts per-user MinIO credentials (from k8s secret)
  - Mounts git credentials (from k8s secret)
  - Injects environment variables for bucket access
  - Error handling: graceful fallback if workspace-service unreachable

- [ ] **Configure JupyterHub storage**
  - Per-user home PVCs: 10Gi, local-path storage class
  - User selector: matches username from Keycloak
  - Test: user home is persistent across pod restarts

- [ ] **Update Jupyter image**
  - Add `jupyterlab-git` extension (git UI in JupyterLab)
  - Add `s3contents` (optional, for MinIO-backed notebook storage)
  - Add git credential helper configuration
  - Rebuild image tag: `jupyter-health-env:latest`

- [ ] **Configure JupyterHub compute profiles**
  - Profile 1: "Standard" (1 CPU, 2GB RAM) - default
  - Profile 2: "Large" (2 CPU, 4GB RAM)
  - Profile 3: "GPU" (1 GPU, 4 CPU, 8GB RAM) - optional, if GPU available on Server 2

- [ ] **Set up JupyterHub idle culling**
  - Timeout: 1 hour (configurable)
  - Check interval: 10 minutes
  - Preserve admin notebooks (optional)

- [ ] **Configure JupyterHub ingress**
  - Hostname: `hpc.dakar.local`
  - TLS: enabled
  - Test: login via Keycloak, spawn notebook

- [ ] **Test JupyterHub Keycloak integration**
  - User login: redirect to auth.hpc.dakar.local
  - User roles: visible in notebook environment
  - Token: accessible in JUPYTERHUB_API_TOKEN env var
  - Workspace-service API: callable with token

---

### Slurm Configuration (Phase 2)

- [ ] **Install Slurm on Server 2**
  - System service (not containerized)
  - Install packages: slurm-client, slurm-slurmctld, slurm-slurmd
  - Version: 22.05+ (recommend latest LTS)

- [ ] **Configure Slurm controller**
  - Edit slurm.conf (Slurm configuration file)
  - Set cluster name, accounting, debug level
  - Define partitions (queues): gpu (default), cpu, debug
  - Define QoS (Quality of Service): gpu_limited, cpu_default
  - Configure GPU allocation: Gres (GPU resources)

- [ ] **Define compute nodes in Slurm**
  - Node 1: 32 CPU, 1 GPU, 128GB RAM
  - Node 2: 32 CPU, 1 GPU, 128GB RAM
  - (Optional) Node 3+: CPU-only nodes
  - Set node state: UP (or DOWN for maintenance)

- [ ] **Configure Slurm user accounts**
  - Create Slurm users: airflow, jupyter (for job submission)
  - Set up passwordless sudo for job submission (if needed)

- [ ] **Configure Slurm accounting**
  - Enable slurmdbd (Slurm Accounting Daemon)
  - Database: PostgreSQL (Server 1, separate schema)
  - Track: CPU hours, GPU hours, memory, wall time

- [ ] **Set up Slurm GPU quotas**
  - Per-user limits: e.g., 100 GPU-hours/month, 1000 CPU-core-hours/month
  - Implement via QoS: GrpGRESMin, GrpGRESRunMin
  - Alert: 80% quota usage

- [ ] **Configure Slurm job logging**
  - Log directory: /var/log/slurm/
  - Retention: 30 days (rotate old logs)
  - Enable debug logging (during setup, reduce for production)

- [ ] **Configure Slurm job submission from JupyterHub**
  - Users in docker container: add srun/sbatch capabilities
  - Mount Slurm socket: /var/run/slurm/
  - Test: submitit.SlurmExecutor() from notebook

- [ ] **Test Slurm integration**
  - Submit simple job from notebook: `submitit.SlurmExecutor().submit(func)`
  - Verify job appears in `squeue`
  - Check job completion: `sinfo`, `sacct`
  - Monitor job output in /scratch/

- [ ] **Set up Slurm monitoring**
  - Export metrics: Prometheus (via slurm_exporter)
  - Metrics: jobs running/pending, GPU utilization, queue depth

- [ ] **Document Slurm operational procedures**
  - Write runbook: managing job queue
  - Write runbook: canceling runaway jobs
  - Write runbook: adjusting quotas
  - Write runbook: troubleshooting job failures

---

### MLflow Deployment (Phase 2)

- [ ] **Deploy MLflow Helm chart**
  - Add `bitnami/mlflow` to Terraform (Server 2)
  - Image: mlflow:latest (or pinned version)
  - Replicas: 1 (HA: 2+ in production)

- [ ] **Configure MLflow backend**
  - Backend store: PostgreSQL (Server 1, separate schema)
  - DSN: `postgresql://health_app:password@pgbouncer.data-stack:5432/health_node`
  - (Create `mlflow` schema in health_node database)

- [ ] **Configure MLflow artifact store**
  - S3 backend: MinIO (Server 1, bucket `modellers/`)
  - S3 endpoint: `http://minio.data-stack.svc.cluster.local:9000`
  - Access key/secret: from k8s secret
  - Artifact storage path: `s3://modellers/mlflow/`

- [ ] **Configure MLflow tracking server**
  - Port: 5000
  - Gunicorn workers: 4
  - Enable file storage fallback (for artifacts if S3 unavailable)

- [ ] **Create MLflow ingress**
  - Hostname: `mlflow.hpc.dakar.local`
  - TLS: enabled
  - Test: access MLflow UI, create experiment, log params

- [ ] **Create MLflow experiments (template)**
  - Experiment 1: malaria-classifier (template for users)
  - Tags: team=ml-platform, project=health-modeling
  - Create via MLflow Python client (mlflow.create_experiment)

- [ ] **Implement MLflow model registry integration**
  - Register models via mlflow.register_model()
  - Tag models: stage=production-candidate (for automated promotion)
  - Implement version numbering: major.minor.patch

- [ ] **Document MLflow operational procedures**
  - Write runbook: accessing MLflow UI
  - Write runbook: logging experiments from notebooks
  - Write runbook: viewing run artifacts
  - Write runbook: promoting models to registry

---

### Workspace Service Deployment (Phase 2)

- [ ] **Implement Workspace Service FastAPI application**
  - Directory: `workspace-service/app/`
  - Files:
    - main.py: FastAPI app factory, startup tasks
    - config.py: Pydantic settings from env vars
    - database.py: PostgreSQL connection pool
    - minio_admin.py: MinIO admin API client
    - k8s_secrets.py: Kubernetes secret read/write
    - models/: workspace, git_config, bucket_grant, dependencies, training_job, model_version, etc. (Pydantic models)
    - api/: routers for workspaces, git, buckets, admin, dependencies, spawn_config

- [ ] **Implement Workspace Service API endpoints**
  - POST /api/v1/workspaces: create workspace
  - GET /api/v1/workspaces: list user's workspaces
  - GET /api/v1/workspaces/{id}: get workspace details
  - PATCH /api/v1/workspaces/{id}: update workspace
  - DELETE /api/v1/workspaces/{id}: archive workspace
  - POST /api/v1/workspaces/{id}/git: link git repo
  - GET /api/v1/buckets: list accessible buckets
  - POST /api/v1/buckets/requests: request bucket access
  - GET /api/v1/workspaces/{id}/dependencies: query dependency graph
  - POST /api/v1/dependencies: record notebook→resource dependency
  - GET /api/v1/users/{username}/spawn-config: (called by pre_spawn_hook)
  - GET /admin/requests: list pending bucket access requests
  - POST /admin/requests/{id}/approve: approve request
  - POST /admin/requests/{id}/deny: deny request
  - GET /health: liveness probe

- [ ] **Implement workspace initialization logic**
  - Create MinIO folder structure: `modellers/{username}/{project}/`
  - Create medallion folders if `use_medallion=true`: bronze/, silver/, gold/, scripts/, notebooks/
  - Create per-user MinIO service account (via MinIO admin API)
  - Create Kubernetes secret: `minio-user-{username}-creds`
  - Create PostgreSQL workspace row

- [ ] **Implement MinIO IAM service account management**
  - Create service account via MinIO admin API
  - Generate access key/secret
  - Create per-user base policy: full access to own prefix
  - Store in Kubernetes secret (read-only by workspace-service SA)
  - Document policy structure: `user-{username}-policy`

- [ ] **Implement GitHub repo linking**
  - Support HTTPS (token), SSH (key), PAT (Personal Access Token)
  - Store credentials in Kubernetes secret: `git-creds-{username}`
  - Pre-configure .gitconfig in user's pod
  - Support: clone, commit, push, pull
  - Handle credential expiration (HTTPS token refresh)

- [ ] **Implement bucket access request workflow**
  - User submits request: bucket name, path prefix, access level, reason
  - Request stored in PostgreSQL: bucket_access_grants (status=pending)
  - Admin reviews via /admin/requests endpoint
  - Admin approves: create MinIO policy, attach to user service account
  - Admin denies: set status=denied, send notification to user

- [ ] **Implement spawn-config endpoint**
  - Called by JupyterHub pre_spawn_hook
  - Return: minio_secret_name, git_secret_name, accessible buckets, git credential type
  - If no config: return graceful defaults (user can start notebook without workspace)

- [ ] **Implement dependency tracking**
  - Record: notebook_path, resource_type (bucket, git_repo, model), resource_ref
  - Query: dependency graph (DAG)
  - Export: for impact analysis (if data deleted, which models affected?)

- [ ] **Implement admin features**
  - Approve/deny bucket access
  - View audit logs: all workspace actions
  - Manage user quotas (GPU hours, storage)
  - Override workspace settings (if needed)

- [ ] **Create Workspace Service Dockerfile**
  - File: `docker/workspace-service/Dockerfile`
  - Base: python:3.11-slim
  - Install: pip packages (fastapi, uvicorn, psycopg2, minio, kubernetes, httpx)
  - ENTRYPOINT: uvicorn app.main:app --host 0.0.0.0 --port 8000

- [ ] **Create Workspace Service Helm chart**
  - Directory: `charts/workspace-service/`
  - Files: Chart.yaml, values.yaml, templates/
  - Templates:
    - deployment.yaml: 1 replica, uvicorn container
    - service.yaml: ClusterIP, port 8000
    - ingress.yaml: `workspaces.hpc.dakar.local`
    - configmap.yaml: non-secret config (MinIO endpoint, PostgreSQL DSN, Keycloak URL)
    - serviceaccount.yaml: for k8s secret access
    - role.yaml: RBAC (get, create, update secrets in data-stack namespace)
    - rolebinding.yaml: bind role to service account

- [ ] **Create Workspace Service Kubernetes secret**
  - Secret: `workspace-service-creds`
  - Keys:
    - minio-access-key: root access key (from minio-creds)
    - minio-secret-key: root secret key
    - db-password: health_app password (from postgres-creds)

- [ ] **Test Workspace Service**
  - Startup: pod runs, logs show healthy
  - Health check: `curl http://workspace-service:8000/health`
  - Create workspace: `POST /api/v1/workspaces`
  - List workspaces: `GET /api/v1/workspaces`
  - Request bucket: `POST /api/v1/buckets/requests`
  - Approve request: `POST /admin/requests/{id}/approve`

- [ ] **Document Workspace Service**
  - API documentation (swagger/openapi)
  - Runbook: creating workspace
  - Runbook: linking GitHub repo
  - Runbook: requesting bucket access
  - Runbook: approving access requests

---

### Unity Catalog Deployment (Phase 2, Optional)

- [ ] **Deploy Unity Catalog Helm chart** (if using local chart or SaaS)
  - Create `charts/unity-catalog/` (if local deployment)
  - Configure: PostgreSQL backend (Server 1), S3 artifact store (MinIO)
  - Replicas: 1

- [ ] **Configure Unity Catalog metastore**
  - Catalogs: health_data
  - Schemas: raw (raw ingested data), standard (processed), published (public)
  - Tables: (auto-created from Spark/Trino queries or manual DDL)

- [ ] **Create table versioning policies**
  - Retention: keep 5 versions (auto-cleanup old)
  - Tagging: version tags (e.g., 2024-Q1, 2024-Q2)
  - Access control: who can read/write each version

- [ ] **Integrate Unity Catalog with Spark**
  - Spark cluster configuration: catalog enabled
  - Users query: `SELECT * FROM health_data.standard.features VERSION AS OF 2`
  - Spark jobs log lineage to Unity Catalog

- [ ] **Integrate Unity Catalog with Trino**
  - Trino connector: iceberg or native UC support
  - Users query: `SELECT * FROM health_data.raw.encounters`
  - Trino logs queries + user info

- [ ] **Implement lineage capture**
  - Unity Catalog events → PostgreSQL workspace.unity_catalog_lineage
  - Track: which table versions used in training, models, reports

---

### Ray Cluster GPU Pooling (Phase 2)

- [ ] **Create Ray Cluster Helm chart**
  - Directory: `charts/ray-cluster/`
  - Files: Chart.yaml, values.yaml, templates/

- [ ] **Configure Ray Head node**
  - Image: rayproject/ray:latest-gpu
  - Resources: requests (cpu: 8, memory: 32Gi), limits (cpu: 16, memory: 64Gi)
  - No GPU needed (coordinator only)
  - 1 replica
  - Expose redis port (6379) for worker registration

- [ ] **Configure Ray Worker nodes (Server 2 GPU)**
  - Image: rayproject/ray:latest-gpu
  - Replicas: 2 (fixed)
  - Resources per worker: requests (gpu: 1, cpu: 8, memory: 64Gi), limits (gpu: 1, cpu: 16, memory: 128Gi)
  - Node selector: server=hpc
  - Ray start params: --num-gpus=1, --num-cpus=8

- [ ] **Configure Ray Worker nodes (Server 3 GPU)**
  - Image: rayproject/ray:latest-gpu
  - Replicas: 4 (min), 6 (max) for auto-scaling
  - Resources per worker: requests (gpu: 1, cpu: 4, memory: 16Gi), limits (gpu: 1, cpu: 8, memory: 32Gi)
  - Node selector: server=serving
  - Ray start params: --num-gpus=1, --num-cpus=4

- [ ] **Configure Ray scheduling policies**
  - Affinity: prefer Server 2 for training jobs, Server 3 for inference
  - Fallback: allow cross-server scheduling if one server full

- [ ] **Deploy Ray Cluster**
  - Helm install: `helm install ray-cluster ./charts/ray-cluster`
  - Verify: ray status, dashboard accessible

- [ ] **Create Ray Cluster ingress**
  - Dashboard hostname: `ray.hpc.dakar.local`
  - Port: 8265
  - Test: view worker status, metrics

- [ ] **Test Ray GPU pooling**
  - Submit distributed training job: Ray Tune
  - Verify: workers across Server 2 and Server 3
  - Monitor: GPU utilization

---

### Docker Image Updates (Phase 2)

- [ ] **Update Jupyter image for Phase 2**
  - File: `docker/jupyter-health-env/Dockerfile`
  - Add packages:
    - System: git, git-credential-store, openssh-client
    - Python: submitit (Slurm job submission), ray[air], pytorch, transformers
    - JupyterLab extensions: jupyterlab-git, (optional) jupyterlab-workspace-tracker
  - Prebuild git config: credential.helper = store
  - Test: submit Slurm job from notebook

- [ ] **Build and import Jupyter image**
  - docker build -t jupyter-health-env:latest .
  - docker save jupyter-health-env:latest | docker load (or k3s ctr images import)
  - Verify: image available in container runtime

- [ ] **Create custom Workspace Service image**
  - File: `docker/workspace-service/Dockerfile`
  - Build: docker build -t workspace-service:latest .
  - Import: docker save | docker load (or k3s ctr images import)

---

### PostgreSQL Schema Extensions (Phase 2)

- [ ] **Create workspace schema in health_node database**
  - Create schema, tables as per TECHNICAL_DESIGN.md [Data Models & Schemas](#data-models--schemas)
  - Run migration: workspace-service applies DDL on startup
  - Verify: tables exist, indexes created, constraints applied

- [ ] **Grant permissions to health_app user**
  - GRANT ALL ON SCHEMA workspace TO health_app
  - GRANT ALL ON ALL TABLES IN SCHEMA workspace TO health_app
  - GRANT ALL ON ALL SEQUENCES IN SCHEMA workspace TO health_app

- [ ] **Create mlflow schema** (for MLflow metadata)
  - Create schema mlflow
  - Configure: MLflow writes run metadata, metrics, params

- [ ] **Set up PostgreSQL replication** (optional, for HA)
  - Create replica PostgreSQL on another node
  - Configure: streaming replication, WAL archival
  - Test: failover from primary to replica

---

### Terraform Updates (Phase 2)

- [ ] **Add Server 2 k8s cluster to Terraform** (if using Terraform for infrastructure)
  - Provision VM/hardware (2x Xeon 64c, 256GB RAM, 2 GPUs)
  - Install k8s (kubeadm, kops, or cloud provider managed)
  - Configure networking: CNI, service CIDR, pod CIDR

- [ ] **Add Keycloak Helm release**
  - helm_release.keycloak block
  - Configure: PostgreSQL backend (Server 1), ingress, resources

- [ ] **Update JupyterHub Helm release**
  - Modify: OAuthenticator, pre_spawn_hook, image tag updates
  - Remove: DummyAuthenticator

- [ ] **Add MLflow Helm release**
  - helm_release.mlflow block
  - Configure: PostgreSQL backend, MinIO artifact store

- [ ] **Add Workspace Service Helm release**
  - helm_release.workspace_service block
  - Configure: image, replicas, ingress, RBAC

- [ ] **Add Ray Cluster Helm release**
  - helm_release.ray_cluster block
  - Configure: head node, worker nodes, GPU resources

- [ ] **Add Slurm configuration** (non-Terraform, system service)
  - (Slurm not managed by Terraform; manual setup documented in runbook)

---

### Integration Testing (Phase 2)

- [ ] **End-to-end workflow test**
  - User logs in via Keycloak
  - User creates workspace via workspace-service
  - User views workspace in JupyterHub
  - User submits training job to Slurm (from notebook)
  - Job logs metrics to MLflow
  - Artifacts stored in MinIO
  - Training job metadata in PostgreSQL

- [ ] **GitHub integration test**
  - User links GitHub repo (HTTPS)
  - User clones repo in notebook
  - User commits + pushes changes
  - Verify: changes in GitHub repository

- [ ] **Bucket access request test**
  - User requests access to `raw` bucket
  - Admin approves request
  - User can now read from `s3://raw/`
  - Verify: MinIO IAM policy attached to user service account

- [ ] **MLflow integration test**
  - User trains model in notebook
  - Metrics logged to MLflow
  - Artifacts stored in MinIO s3://modellers/
  - Model visible in MLflow UI

---

## Phase 3+: Model Serving & Analytics Tasks

### Harbor Container Registry

- [ ] **Deploy Harbor Helm chart**
  - Add `harbor/harbor` to Terraform (Server 3)
  - Configure: admin password, secret key, ingress

- [ ] **Configure Harbor projects + RBAC**
  - Project: models (for trained models)
  - RBAC: viewers (read), reporters (edit), admins (delete)

- [ ] **Create Harbor API token**
  - Token for Model Registry Service (Server 2) to push images
  - Store in k8s secret: `harbor-api-token`

- [ ] **Create Harbor ingress**
  - Hostname: `harbor.serving.dakar.local`
  - TLS: enabled
  - Test: login via web UI, browse projects

- [ ] **Enable Harbor image scanning**
  - Trivy scanner: enabled by default
  - Scan policy: scan on push, fail on critical CVEs

- [ ] **Document Harbor operational procedures**
  - Write runbook: pushing images manually
  - Write runbook: viewing scan results
  - Write runbook: managing access tokens
  - Write runbook: disk usage cleanup

---

### KServe Model Serving

- [ ] **Deploy KServe operator**
  - KServe already prepared in Phase 1 (CRDs + controller)
  - Verify: KServe API v1beta1 available

- [ ] **Create KServe namespace + RBAC**
  - Namespace: kserve (existing)
  - ServiceAccount: kserve-sa
  - Secret: harbor-creds (for image pull)

- [ ] **Implement KServe InferenceService automation**
  - Triggered by: Model Approval Service (Phase 3)
  - Creates: InferenceService CR with Harbor image
  - Waits for: predictor pod to be ready
  - Exposes: HTTP endpoint at model_name.kserve.svc

- [ ] **Configure KServe auto-scaling**
  - Min replicas: 1
  - Max replicas: 4
  - Metrics: CPU, memory, custom metrics (RPS)

- [ ] **Configure KServe traffic splitting** (canary)
  - Gradual rollout: 10% traffic to new version initially
  - Increase: manually or auto-based on metrics
  - Rollback: if error rate > 5% or latency > 200ms

- [ ] **Create KServe monitoring**
  - Export metrics: Prometheus (inference latency, throughput, errors)
  - Create Grafana dashboard: latency percentiles, error rate, GPU utilization

- [ ] **Test KServe deployment**
  - Deploy test model: simple sklearn model
  - Make predictions: `curl http://model.kserve/predict -X POST -d '{...}'`
  - Verify: metrics in Prometheus

---

### Model Registry Service (Phase 3)

- [ ] **Implement Model Registry Service**
  - FastAPI application (Python)
  - Triggered by: MLflow webhook or polling
  - Fetches: model artifact from MinIO s3://modellers/
  - Builds: Dockerfile wrapper around artifact
  - Pushes: image to Harbor

- [ ] **Implement model artifact fetching**
  - MLflow run ID input
  - Query MLflow API: metadata, metrics, params
  - Download: artifacts (model.pkl, model.pt, etc.) from MinIO
  - Extract: requirements.txt, training metadata

- [ ] **Implement Dockerfile generation**
  - Base image: python:3.11-slim
  - Copy: model artifact, inference script, requirements.txt
  - ENTRYPOINT: inference.py (serves on port 8000)
  - Tag: `harbor.../models/{model_name}:{version}`

- [ ] **Implement image building + pushing**
  - Docker build: runs in Model Registry pod
  - Docker push: to Harbor (authenticate with API token)
  - Handle: build failures, push failures, registry down

- [ ] **Implement model lineage insertion**
  - Query: training job metadata from PostgreSQL
  - Query: MLflow run details
  - Insert: model_versions row (code version, data buckets, metrics, etc.)
  - Insert: model_approvals row (status=pending)

- [ ] **Implement webhook** (optional, for auto-registration)
  - MLflow webhook: notify Model Registry Service when run tagged
  - Endpoint: `/webhook/mlflow`
  - Trigger: model registration + build

- [ ] **Create Model Registry Service Helm chart**
  - Templates: deployment, service, configmap, secrets

- [ ] **Test Model Registry Service**
  - Tag MLflow run with "stage=production-candidate"
  - Verify: image built and pushed to Harbor
  - Verify: model_versions + model_approvals rows in PostgreSQL

---

### Model Approval Service (Phase 3)

- [ ] **Implement Model Approval Service**
  - FastAPI application (Python)
  - Queries: PostgreSQL for pending model_approvals
  - Admin endpoints: /admin/approvals, /admin/requests/{id}/approve
  - Web dashboard: list pending, view metrics, approve/deny buttons

- [ ] **Implement admin dashboard**
  - List pending model versions
  - Display: metrics (accuracy, auc, latency), code version, training data, cost
  - Approval checklist: metrics acceptable, code reviewed, data documented, no drift
  - Approve button: creates KServe InferenceService

- [ ] **Implement KServe InferenceService creation**
  - Input: model version, environment (staging/production)
  - Generate: InferenceService YAML
  - Apply: to Server 3 k8s cluster
  - Wait: for predictor pods to reach Ready state
  - Return: endpoint URL

- [ ] **Implement approval workflow**
  - User requests: via workspace-service (Phase 2)
  - Admin reviews: model metrics, code, data, tests
  - Admin approves: via web dashboard
  - Service creates: KServe InferenceService
  - Service logs: admin_audit_log entry

- [ ] **Implement rollback capability**
  - Admin: clicks "Rollback to v1.0.0" (previous version)
  - Service: updates InferenceService.spec.predictor.image to previous image
  - Service: updates model_deployments.rollback_from_version
  - Service: logs reason to admin_audit_log

- [ ] **Implement model performance monitoring**
  - Query: inference_logs (predictions, latency, errors)
  - Compute: p50, p95, p99 latency, error rate, request volume
  - Store: in model_deployments table (for dashboard display)
  - Alert: if latency > 200ms or error rate > 5%

- [ ] **Create Model Approval Service Helm chart**
  - Templates: deployment, service, ingress, configmap

- [ ] **Test Model Approval Service**
  - Create mock model_approvals row (pending)
  - Navigate to admin dashboard
  - Click Approve
  - Verify: KServe InferenceService created
  - Verify: model_deployments row inserted

---

### Trino SQL Query Engine (Phase 3)

- [ ] **Deploy Trino Helm chart**
  - Add `trino/trino` to Terraform (Server 3)
  - Coordinator replicas: 1
  - Worker replicas: 2-3

- [ ] **Configure Trino S3 connector**
  - Connector: hive (for S3/MinIO)
  - Endpoint: `http://minio.data-stack.svc.cluster.local:9000`
  - Access key/secret: from k8s secret
  - Hive metastore: (optional, if using metastore for schema)

- [ ] **Configure Trino PostgreSQL connector**
  - Connector: postgresql
  - Connection: `jdbc:postgresql://pgbouncer.data-stack:5432/health_node`
  - Credentials: trino user + password

- [ ] **Configure Trino Iceberg connector** (optional, for Unity Catalog)
  - Connector: iceberg
  - Metastore: Hive metastore (from Unity Catalog)

- [ ] **Create Trino catalogs**
  - Catalog: s3 (MinIO: raw, standard, published, modellers buckets)
  - Catalog: postgres (Server 1: health_node database tables)
  - Catalog: iceberg (optional, for versioned tables)

- [ ] **Create Trino schemas**
  - Catalog s3 schemas:
    - default: s3://raw/
    - standard: s3://standard/
    - modellers: s3://modellers/
  - Catalog postgres schemas:
    - public (health domain tables)
    - workspace (user workspaces, lineage, deployments)

- [ ] **Create Trino ingress**
  - Hostname: `trino.serving.dakar.local`
  - Port: 8080 (web UI)
  - TLS: enabled

- [ ] **Test Trino queries**
  - Query S3: `SELECT * FROM s3.default.raw_encounters LIMIT 10`
  - Query PostgreSQL: `SELECT * FROM postgres.workspace.model_versions`
  - Join: `SELECT ... FROM s3.default.encounters JOIN postgres.workspace.model_versions`

- [ ] **Document Trino operational procedures**
  - Write runbook: common queries
  - Write runbook: adding new catalog/connector
  - Write runbook: troubleshooting slow queries

---

### FastAPI Endpoints (Phase 3)

- [ ] **Implement FastAPI endpoints wrapper**
  - Directory: `services/fastapi-endpoints/`
  - Main endpoint: /api/v1/models/{model_name}/predict
  - Input validation, rate limiting, response formatting

- [ ] **Implement prediction endpoints**
  - Endpoint: POST /api/v1/{model_name}/predict
  - Input: JSON features
  - Call: KServe model endpoint (http://model.kserve/predict)
  - Output: prediction, confidence, explanation

- [ ] **Implement feature preprocessing**
  - Validate input schema
  - Transform features (scaling, encoding, etc.)
  - Handle missing values, outliers

- [ ] **Implement post-processing**
  - Format response: JSON with prediction, confidence, metadata
  - Add model version, timestamp, request ID
  - Include explanation (SHAP, LIME if available)

- [ ] **Implement inference logging**
  - Log: request ID, input features, prediction, latency, timestamp
  - Store: in PostgreSQL inference_logs table
  - Handle: async logging (don't block response)

- [ ] **Implement rate limiting**
  - Per-user limits: e.g., 100 requests/minute
  - Per-IP limits: e.g., 1000 requests/minute
  - Return: 429 Too Many Requests if exceeded

- [ ] **Implement Keycloak authentication**
  - Verify: JWT token from Authorization header
  - Extract: user ID, roles, custom attributes
  - Enforce: authorization (who can call which endpoints)

- [ ] **Implement error handling**
  - Graceful failures: if KServe unavailable, return 503
  - Clear error messages: include retry advice
  - Logging: all errors logged for debugging

- [ ] **Create FastAPI Dockerfile + Helm chart**
  - Deployment: Server 3 k8s
  - Replicas: 2-4 (auto-scale)
  - Ingress: `api.serving.dakar.local` or `api.dakar.local`

- [ ] **Test FastAPI endpoints**
  - Call: /api/v1/malaria-classifier/predict (with sample input)
  - Verify: response includes prediction, confidence, metadata
  - Monitor: request latency, error rate

---

### MinIO Hot/Cold Storage Tiering (Phase 3)

- [ ] **Create MinIO lifecycle policies**
  - JSON policy file: `config/minio-lifecycle-policy.json`
  - Rules:
    1. inference-logs: move to Glacier after 60 days
    2. old-artifacts: move to Glacier after 180 days
    3. archive: delete after 7 years (compliance)

- [ ] **Apply lifecycle policies to MinIO**
  - Command: `mc ilm import local/logs < policy.json`
  - Test: upload old file, verify transition after threshold

- [ ] **Configure hot tier storage** (Server 1 MinIO)
  - NVMe SSD or high-IOPS storage
  - Retention: 0-60 days
  - Cost: ~$0.10/GB/month

- [ ] **Configure cold tier storage** (Glacier or Archive)
  - AWS Glacier or GCS Archive
  - Retention: 60+ days
  - Cost: ~$0.02/GB/month

- [ ] **Test storage tiering**
  - Upload file to hot tier
  - Wait for transition threshold (or force via MinIO admin API)
  - Verify: file moved to cold tier
  - Restore: retrieve file from cold tier (takes 24 hours)

- [ ] **Monitor storage costs**
  - Track: hot tier size, cold tier size, egress costs
  - Alert: if costs exceed budget

- [ ] **Document tiering operational procedures**
  - Write runbook: restoring from cold tier
  - Write runbook: adjusting retention policies
  - Write runbook: estimating costs

---

### Terraform Updates (Phase 3)

- [ ] **Add Server 3 k8s cluster** (if using Terraform)
  - Provision: cloud VM/kubernetes service
  - Configure: networking, security groups, storage

- [ ] **Add Harbor Helm release**
  - helm_release.harbor block

- [ ] **Update KServe Helm release**
  - Enable: (from Phase 1 prepared state)
  - Configure: full RBAC, ServiceAccount, secrets

- [ ] **Add Trino Helm release**
  - helm_release.trino block

- [ ] **Add Model Registry Helm release**
  - helm_release.model_registry_service block

- [ ] **Add Model Approval Helm release**
  - helm_release.model_approval_service block

- [ ] **Add FastAPI Helm release**
  - helm_release.fastapi_endpoints block

---

## Cross-Cutting Tasks

### Security & Identity

- [ ] **Implement Kubernetes RBAC**
  - Roles per namespace (data-stack, monitoring, kserve, harbor, etc.)
  - Least privilege: each service has minimal required permissions
  - ServiceAccount per service (not default)

- [ ] **Implement network policies**
  - Ingress rules: restrict traffic to needed ports
  - Egress rules: restrict outbound (data exfiltration prevention)
  - Test: blocked traffic returns connection refused

- [ ] **Configure TLS certificates**
  - Use cert-manager for automatic certificate generation
  - Issuer: Let's Encrypt (if public) or self-signed (if private)
  - Renewal: automatic before expiry
  - Test: HTTPS connectivity, certificate validity

- [ ] **Implement secret encryption at rest**
  - Kubernetes: enable encryption-at-rest for etcd
  - (Configuration depends on k8s deployment method)

- [ ] **Set up VPN/tunnel between servers**
  - VPN type: WireGuard or OpenVPN
  - Keys: generated via deploy/bootstrap.sh
  - Firewall: allow VPN ports, block direct inter-server communication
  - Test: ping across tunnel, latency < 50ms

- [ ] **Configure credential rotation**
  - Schedule: annually or on compromise
  - Credentials to rotate:
    - MinIO root password
    - PostgreSQL passwords
    - Keycloak passwords
    - Harbor admin password
    - API tokens (workspace-service, model-approval, etc.)

- [ ] **Implement audit logging**
  - PostgreSQL: admin_audit_log table (all DDL, DML, admin actions)
  - Kubernetes: API audit logs (all API calls)
  - MinIO: access logs (S3 API calls)
  - Airflow: task logs (DAG execution)
  - Retention: 7 years (compliance)

- [ ] **Configure data access logging**
  - MinIO: log all S3 GET/PUT operations (bucket=raw, standard, published)
  - PostgreSQL: log all SELECT on sensitive tables
  - KServe: log inference requests (for monitoring data drift)

---

### Monitoring & Observability

- [ ] **Implement application metrics export**
  - Workspace Service: Prometheus metrics (API latency, requests, errors)
  - MLflow: custom metrics (experiment count, model count)
  - KServe: inference metrics (latency, throughput, errors) - built-in
  - FastAPI: application metrics (requests, latency) - built-in

- [ ] **Implement logging infrastructure** (optional, Phase 3+)
  - Centralized logs: ELK stack or Loki
  - Log collectors: Fluentd or Filebeat on each pod
  - Retention: 30 days hot, 90 days cold

- [ ] **Create comprehensive Grafana dashboards**
  - Cluster health: node CPU, memory, disk, network
  - Application health: Pod status, restarts, resource usage
  - Data pipeline: Airflow DAG execution, task latency
  - ML platform: training jobs, experiments, models
  - Inference: KServe latency, throughput, error rate
  - Cost: training cost/user, inference cost/model
  - Lineage: data dependencies, model dependencies

- [ ] **Implement alerting rules**
  - Critical: PostgreSQL down, MinIO disk full, KServe error rate > 5%
  - Warning: latency p99 > 200ms, training quota > 80%
  - Info: pod restarts, ingress certificate expiry

- [ ] **Implement health checks**
  - Liveness probes: pod restarts if unhealthy
  - Readiness probes: remove from load balancer if not ready
  - Each service: implement /health endpoint

- [ ] **Implement distributed tracing** (optional, Phase 3+)
  - Jaeger or similar
  - Trace: user request through multiple services
  - Identify: bottlenecks, failures

---

### Documentation & Runbooks

- [ ] **Write operational runbooks**
  - Backup/restore procedures
  - Disaster recovery (Server 2 crash → Server 1 fallback)
  - Upgrading components (Helm charts, k8s version)
  - Scaling (adding GPU nodes, increasing PVCs)
  - Troubleshooting (common error messages, diagnostics)
  - Incident response (data breach, service outage, data corruption)

- [ ] **Write user documentation**
  - Getting started: how to create account, sign in
  - Workspace creation: step-by-step guide
  - GitHub linking: HTTPS vs SSH vs PAT
  - Training jobs: submitting Slurm jobs from JupyterLab
  - Model deployment: tagging MLflow run, waiting for approval
  - Using predictions: calling FastAPI endpoints

- [ ] **Write administrator documentation**
  - Keycloak: user management, role assignment, password resets
  - Workspace Service: approving bucket access, quota management
  - Model Approval: reviewing models, approving deployments, rollbacks
  - Monitoring: interpreting dashboards, responding to alerts
  - Maintenance: backups, scaling, upgrades

- [ ] **Create architecture diagrams**
  - System overview: three servers, services, data flow
  - Network topology: VPN, firewall, DNS
  - Data flow: ingest → train → approve → serve → monitor
  - Component interaction: API calls, data exchange

- [ ] **Write API documentation**
  - OpenAPI/Swagger for FastAPI services
  - Examples: curl, Python, JavaScript
  - Error codes + explanations
  - Rate limits, authentication

---

### Testing & Validation

- [ ] **Write integration tests**
  - End-to-end: user login → create workspace → submit job → log metrics → train model
  - GitHub integration: clone, commit, push
  - Bucket access: request → approve → access
  - Model deployment: tag → register → approve → serve
  - Prediction: call endpoint → log inference → verify metrics

- [ ] **Write performance tests**
  - MinIO: S3 throughput (MB/s), latency (ms)
  - PostgreSQL: query latency (ms), connection pool performance
  - JupyterHub: notebook spawn time (seconds)
  - KServe: inference latency (ms), throughput (predictions/sec)

- [ ] **Write load tests**
  - Concurrent users: how many simultaneous JupyterHub pods?
  - Concurrent training jobs: how many Slurm jobs in parallel?
  - Concurrent predictions: how many inference requests/sec can KServe handle?
  - Stress test: scale to limits, verify recovery

- [ ] **Write disaster recovery tests**
  - PostgreSQL: restore from backup, verify data integrity
  - MinIO: restore from backup, verify bucket contents
  - Server 2 failover: verify Server 1 can handle fallback jobs
  - Network: simulate VPN outage, verify recovery

- [ ] **Write security tests**
  - RBAC: verify unauthorized users cannot access resources
  - Network policies: verify blocked traffic is blocked
  - TLS: verify encrypted communication
  - Secrets: verify credentials not exposed in logs/configs

---

### Deployment & Infrastructure

- [ ] **Create deployment playbooks**
  - Ansible playbooks (or equivalent) for repeatable deployments
  - Infrastructure provisioning: servers, networks, storage
  - Software installation: k8s, Helm, Docker, Slurm
  - Application deployment: Helm charts, secrets, configurations

- [ ] **Implement Infrastructure as Code (IaC)**
  - Terraform: all cloud resources, k8s resources
  - Helm: all applications
  - Gitops: deploy via git commits (Flux or ArgoCD)

- [ ] **Version all configurations**
  - Git: TECHNICAL_DESIGN.md, OPERATIONS_GUIDE.md, deploy scripts
  - Helm: chart versions (semantic versioning)
  - Images: Docker image tags (semantic versioning)
  - Code: git commit hashes for all components

- [ ] **Create deployment checklist**
  - Pre-deployment: hardware, network, DNS, TLS
  - Deployment order: Phase 1 → Phase 2 → Phase 3+
  - Post-deployment: verification, testing, documentation

---

## Integration & Validation Tasks

### Cross-Phase Integration

- [ ] **Integrate Phase 1 → Phase 2**
  - Server 1 PostgreSQL accessible from Server 2 (via VPN tunnel)
  - Server 1 MinIO accessible from Server 2 (via S3 API)
  - Workspace Service can read/write to both
  - JupyterHub can read/write to both

- [ ] **Integrate Phase 2 → Phase 3**
  - Model Registry (Server 2) can push images to Harbor (Server 3)
  - Model Approval (Server 3) can create KServe services (Server 2)
  - Inference logs (Server 3) synced to PostgreSQL (Server 1)
  - Trino (Server 3) can query MinIO (Server 1) + PostgreSQL (Server 1)

- [ ] **Integrate Keycloak across all servers**
  - JupyterHub (Server 2): authenticate via Keycloak
  - Airflow (Server 1): authenticate via Keycloak (Phase 2 upgrade)
  - KServe (Server 3): authenticate via Keycloak (admin dashboard)
  - All APIs: verify JWT tokens from Keycloak

---

### End-to-End Validation

- [ ] **Complete workflow validation**
  - User 1: alice (data-scientist)
    1. Logs in via Keycloak
    2. Creates workspace: malaria-classifier
    3. Checks out GitHub repo
    4. Submits training job (Slurm)
    5. Job logs metrics to MLflow
    6. Model artifact in MinIO
    7. Tags MLflow run: "production-candidate"
  - System 1: Model Registry Service
    1. Detects tag
    2. Builds Docker image
    3. Pushes to Harbor
    4. Updates PostgreSQL: model_versions (pending)
  - User 2: bob (model-reviewer)
    1. Logs in via Keycloak
    2. Opens Model Approval dashboard
    3. Reviews: metrics (accuracy 94%), code (commit hash), data (raw/2024-Q1)
    4. Approves
  - System 2: Model Approval Service
    1. Creates KServe InferenceService
    2. Waits for predictor pods ready
    3. Endpoint: malaria-classifier.kserve
  - User 3: charlie (application)
    1. Calls: POST /api/v1/malaria-classifier/predict
    2. Receives: prediction, confidence, explanation
    3. Inference logged to PostgreSQL
  - Admin: infrastructure-admin
    1. Views Grafana dashboard
    2. Sees: model latency p99=85ms, error rate=0.1%, GPU utilization=60%
    3. Queries: which models use raw/health-data/2024-Q1?
    4. Finds: malaria-classifier, 4 other models
    5. Plans: archive old version in 30 days

- [ ] **Failure scenario validation**
  - Server 2 crash
    - Slurm jobs interrupted (users notified)
    - Lightweight jobs redirect to Server 1 Airflow
    - Verify: jobs complete on Server 1
  - Server 1 PostgreSQL down
    - Server 2 + 3 services fail (expected)
    - Restore from backup
    - Verify: all services recover

- [ ] **Scale validation**
  - 100 users in Keycloak
  - 50 concurrent JupyterHub notebooks
  - 20 concurrent Slurm training jobs
  - 10,000 predictions/sec to KServe
  - Monitor: resource usage, latency, error rate
  - Verify: no service degradation

---

### Documentation Validation

- [ ] **Review all documentation**
  - TECHNICAL_DESIGN.md: complete, accurate, matches implementation
  - DEPLOYMENT_GUIDE.md: step-by-step, tested
  - OPERATIONS_GUIDE.md: runbooks cover all scenarios
  - ARCHITECTURE.md: diagrams accurate, terminology consistent
  - API documentation: OpenAPI/Swagger generated, examples work

- [ ] **Verify documentation accessibility**
  - README.md: clear, includes quick start
  - Terminology: consistent across all docs
  - Cross-references: links work
  - Examples: tested, reproducible

---

## Task Completion Criteria

For each task, completion is verified by:

1. **Code:** Implementation matches TECHNICAL_DESIGN.md specification
2. **Testing:** Unit tests pass, integration tests pass
3. **Documentation:** Runbook written, API documented
4. **Deployment:** Deployed to target environment, accessible, health checks pass
5. **Monitoring:** Metrics exported to Prometheus, dashboard visible
6. **Validation:** End-to-end workflow verified, no regressions

---

**End of Task List**

