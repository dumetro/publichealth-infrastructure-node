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
```

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

Notes:

- Local charts are optional. If charts/unity-catalog or charts/mlflow are missing, deploy-node.sh skips those releases with a warning.
- Spark operator now uses config/values/spark-values.yaml.
- Trino Unity Catalog token is injected at deploy time from UNITY_CATALOG_ADMIN_TOKEN.
- Bootstrap now also builds and imports a local PostgreSQL image with postgis + pgvector into k3s containerd.
- Dev proxy now includes routes for Postgres and PgBouncer:
	- `postgres.health-node.localhost:1355`
	- `pgbouncer.health-node.localhost:1355`

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
