# publichealth-infrastructure-node
Public Health Infrastructure Node for AI workloads

This repository supports two deployment methods:

1. Shell bootstrap plus Helm scripts in deploy/
2. Terraform-based Helm provisioning in terraform/

Prerequisites

- Ubuntu 22.04+ for deploy/bootstrap.sh
- Docker, k3s, kubectl, Helm, yq (bootstrap script installs these)
- Terraform 1.5+ for the Terraform alternative

Required secrets

Do not commit real credentials to config files. Export these in your shell before deploy:

```bash
export MINIO_ROOT_PASSWORD='replace-with-strong-password'
export UNITY_CATALOG_ADMIN_TOKEN='replace-with-unity-catalog-token'
export GRAFANA_ADMIN_PASSWORD='replace-with-grafana-admin-password'
export POSTGRES_SUPERUSER_PASSWORD='replace-with-postgres-superuser-password'
export POSTGRES_APP_PASSWORD='replace-with-postgres-app-password'
export AIRFLOW_FERNET_KEY='replace-with-airflow-fernet-key'
export AIRFLOW_WEBSERVER_SECRET_KEY='replace-with-airflow-webserver-secret-key'
export AIRFLOW_ADMIN_PASSWORD='replace-with-airflow-admin-password'
```

If you use Vault or an external secret controller, you can provision the Kubernetes secret
`airflow-secrets` out-of-band instead of exporting the Airflow variables above. The secret
must contain these keys:

- `sql_alchemy_conn`
- `fernet_key`
- `webserver_secret_key`
- `admin_password`

PostgreSQL stack (new)

- PostgreSQL is deployed via the Bitnami chart as a StatefulSet with a PVC.
- The image is built locally from [docker/postgres-health-ext/Dockerfile](docker/postgres-health-ext/Dockerfile) and includes:
	- `postgis` for spatial data handling
	- `pgvector` for embedding/vector storage
- PgBouncer is deployed as an in-cluster Deployment and exposed as `pgbouncer.data-stack.svc.cluster.local:5432`.
- PostgreSQL is exposed in-cluster as `postgresql.data-stack.svc.cluster.local:5432`.

Persistence model

- Storage is backed by k3s `local-path` (configured in [config/env-config.yaml](config/env-config.yaml)).
- PostgreSQL persistence is configured in [config/values/postgres-values.yaml](config/values/postgres-values.yaml).
- This survives pod/container restarts and pod recreation on the same node.
- Node/disk loss is not covered by local-path storage; add backups for disaster recovery.

PostgreSQL backups

- A `postgres-backup` CronJob now runs on the schedule defined in [config/env-config.yaml](config/env-config.yaml).
- Backups are written to a dedicated `postgres-backups` PVC on the same `local-path` storage class.
- Each run writes:
	- a compressed database dump: `${POSTGRES_DB}-YYYYmmdd-HHMMSS.dump`
	- a globals dump: `globals-YYYYmmdd-HHMMSS.sql`
- Retention is enforced by age in days on the backup PVC.
- This protects against accidental pod recreation and logical mistakes more gracefully than relying on the primary database PVC alone, but it is still local-node storage rather than off-node disaster recovery.

Manual backup trigger

```bash
JOB_NAME="postgres-backup-manual-$(date +%s)"
kubectl create job --from=cronjob/postgres-backup "$JOB_NAME" -n data-stack
kubectl wait --for=condition=complete job/"$JOB_NAME" -n data-stack --timeout=10m
kubectl logs job/"$JOB_NAME" -n data-stack
```

Restore note

- The backup job creates standard `pg_dump` and `pg_dumpall --globals-only` artifacts.
- Restore should be performed into a recreated PostgreSQL pod using the preserved backup PVC contents or by copying those files off the node before a migration/rebuild.

Current script path (shell + Helm)

```bash
sudo bash deploy/bootstrap.sh
bash deploy/setup-secrets.sh
bash deploy/deploy-node.sh
bash deploy/dev-proxy.sh
bash tests/validate-node.sh
```

## Bootstrap

Bootstrap (`deploy/bootstrap.sh`) is a one-time provisioning step that prepares the OS and cluster before any application workloads are deployed. It must complete successfully before `deploy/deploy-node.sh` is run.

### What bootstrap does

| Step | What it installs / configures |
|------|-------------------------------|
| 1 | System packages: curl, wget, ca-certificates, Docker |
| 2 | yq (YAML processor) |
| 3 | Helm |
| 4 | k3s (Kubernetes), waits for API and node Ready |
| 5 | kubeconfig for the calling user (`~/.kube/config`) |
| 6 | Helm repositories (ingress-nginx, bitnami, prometheus-community, etc.) |
| 7 | Node.js 20 and portless reverse proxy |
| 8 | Custom Jupyter image built and imported into k3s containerd |
| 9 | Custom PostgreSQL image (postgis + pgvector) built and imported |
| 10 | Kubernetes namespace and secrets (`setup-secrets.sh`) |
| 11 | portless proxy started on port 1355 |

### What success looks like

When bootstrap completes cleanly you will see:

```
==================================================
  Bootstrap complete!
==================================================
```

Verify the cluster state before proceeding:

```bash
# Node is Ready
kubectl get nodes -o wide

# k3s system pods are Running
kubectl get pods -n kube-system

# Helm repos registered
helm repo list

# Custom images are in k3s containerd
k3s ctr images list | grep -E 'jupyter-health-env|postgres-health-ext'

# Namespace and secrets exist
kubectl get ns data-stack
kubectl get secrets -n data-stack
```

Expected node output:

```
NAME            STATUS   ROLES                  AGE   VERSION
who-epr-his-dk  Ready    control-plane,master   2m    v1.30.4+k3s1
```

### Next steps after bootstrap

Bootstrap only provisions the platform layer. Application workloads are deployed separately:

1. **Export secrets** — required before the next step (see [Required secrets](#required-secrets) above):
   ```bash
   export MINIO_ROOT_PASSWORD='...'
   export POSTGRES_SUPERUSER_PASSWORD='...'
   # ... (all variables listed in Required secrets section)
   ```

2. **Deploy application stack:**
   ```bash
   bash deploy/deploy-node.sh
   ```

3. **Start the dev proxy** (maps cluster services to named local URLs):
   ```bash
   bash deploy/dev-proxy.sh
   ```

4. **Run smoke tests:**
   ```bash
   bash tests/validate-node.sh
   ```

### Service endpoints

After `deploy-node.sh` and `dev-proxy.sh` complete, services are reachable via portless (port 1355) from the host machine, and via in-cluster DNS from within pods.

#### Host access (via portless on port 1355)

| Service | URL |
|---------|-----|
| JupyterHub | http://jupyter.health-node.localhost:1355 |
| Grafana | http://grafana.health-node.localhost:1355 |
| Airflow | http://airflow.health-node.localhost:1355 |
| MLflow | http://mlflow.health-node.localhost:1355 |
| Trino | http://trino.health-node.localhost:1355 |
| MinIO | http://minio.health-node.localhost:1355 |
| PgBouncer | http://pgbouncer.health-node.localhost:1355 |
| PostgreSQL | http://postgres.health-node.localhost:1355 |

#### In-cluster ingress (add node IP to `/etc/hosts`)

Add the node's IP to `/etc/hosts` (replace `<NODE_IP>` with the output of `hostname -I | awk '{print $1}'`):

```
<NODE_IP>  jupyter.health-node.local
<NODE_IP>  grafana.health-node.local
```

| Service | Hostname |
|---------|----------|
| JupyterHub | http://jupyter.health-node.local |
| Grafana | http://grafana.health-node.local |

#### In-cluster service DNS (pod-to-pod)

| Service | DNS name | Port |
|---------|----------|------|
| PostgreSQL (direct) | `postgresql.data-stack.svc.cluster.local` | 5432 |
| PostgreSQL (via PgBouncer) | `pgbouncer.data-stack.svc.cluster.local` | 5432 |

Notes:

- Local charts are optional. If charts/unity-catalog or charts/mlflow are missing, deploy-node.sh skips those releases with a warning.
- Spark operator now uses config/values/spark-values.yaml.
- Airflow now uses config/values/airflow-values.yaml.
- Airflow and Spark run as separate Helm releases and separate Kubernetes workloads.
- Airflow installs the Spark provider package `apache-airflow-providers-apache-spark` during deployment.
- Airflow secrets are read from the Kubernetes secret `airflow-secrets`; this can be created by deploy/setup-secrets.sh or synced from Vault/External Secrets.
- Trino Unity Catalog token is injected at deploy time from UNITY_CATALOG_ADMIN_TOKEN.
- Bootstrap now also builds and imports a local PostgreSQL image with postgis + pgvector into k3s containerd.
- Dev proxy now includes routes for Postgres and PgBouncer:
	- `postgres.health-node.localhost:1355`
	- `pgbouncer.health-node.localhost:1355`

Airflow + Spark integration

- Spark provider installation is currently handled in deployment via `config/values/airflow-values.yaml` using:
	- `extraPipPackages: [apache-airflow-providers-apache-spark]`
- This means Airflow pods install the provider at startup. In restricted/offline environments, its recommended to use a custom Airflow image with the provider pre-baked and set that image in Airflow values.

Verify provider installation after deploy

```bash
kubectl exec -n data-stack deployment/airflow-scheduler -- \
	python -c "import airflow.providers.apache.spark; print('spark provider ok')"
```

How Airflow communicates with Spark jobs in this repo

- Spark workloads are submitted as Kubernetes `SparkApplication` resources (`sparkoperator.k8s.io/v1beta2`), for example in `scripts/etl/silver-etl-job.yaml`.
- Airflow should create/update those `SparkApplication` resources via Kubernetes API (not by talking to a standalone Spark master service).
- Spark Operator watches the CRDs and creates driver/executor pods.
- Airflow then monitors `SparkApplication` status and marks task success/failure.

RBAC needed for Airflow to submit SparkApplication resources

Apply a Role/RoleBinding for the Airflow service account used to run task pods:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
	name: airflow-spark-submit
	namespace: data-stack
rules:
	- apiGroups: ["sparkoperator.k8s.io"]
		resources: ["sparkapplications", "sparkapplications/status"]
		verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
	name: airflow-spark-submit
	namespace: data-stack
subjects:
	- kind: ServiceAccount
		name: airflow-worker
		namespace: data-stack
roleRef:
	apiGroup: rbac.authorization.k8s.io
	kind: Role
	name: airflow-spark-submit
```

Replace `airflow-worker` with the service account used by your Airflow task pods.

Terraform alternative

Terraform manages namespaces, required Kubernetes secrets, and Helm releases with explicit dependency ordering.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with local secret values (file is gitignored)
terraform init
terraform plan
terraform apply
```

Terraform notes:

- Set deploy_optional_local_charts=true only if local charts exist in charts/.
- Terraform does not replace OS bootstrap tasks (apt installs, k3s install, Docker image build/import).
- Terraform now includes PostgreSQL and PgBouncer resources. Ensure local PostgreSQL image `postgres-health-ext:16` is built and imported before `terraform apply`.
- Terraform also creates the `postgres-backups` PVC and `postgres-backup` CronJob using the same local-path persistence model.
- Terraform also provisions the `airflow-secrets` secret from variables and deploys Airflow with config/values/airflow-values.yaml.
