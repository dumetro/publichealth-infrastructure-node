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
```

Current script path (shell + Helm)

```bash
sudo bash deploy/bootstrap.sh
bash deploy/setup-secrets.sh
bash deploy/deploy-node.sh
bash deploy/dev-proxy.sh
```

Notes:

- Local charts are optional. If charts/unity-catalog or charts/mlflow are missing, deploy-node.sh skips those releases with a warning.
- Spark operator now uses config/values/spark-values.yaml.
- Trino Unity Catalog token is injected at deploy time from UNITY_CATALOG_ADMIN_TOKEN.

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
