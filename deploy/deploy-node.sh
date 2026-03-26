#!/bin/bash
set -euo pipefail

CONFIG_FILE="config/env-config.yaml"
NAMESPACE=$(yq e '.global.namespace' "$CONFIG_FILE")
DOMAIN=$(yq e '.global.domain' "$CONFIG_FILE")

MINIO_ROOT_USER="${MINIO_ROOT_USER:-$(yq e '.minio.rootUser' "$CONFIG_FILE")}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
if [[ -z "$MINIO_ROOT_PASSWORD" ]]; then
  MINIO_ROOT_PASSWORD="$(yq e '.minio.rootPassword' "$CONFIG_FILE")"
fi

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
if [[ -z "$GRAFANA_ADMIN_PASSWORD" ]]; then
  GRAFANA_ADMIN_PASSWORD="$(yq e '.monitoring.grafana.adminPassword' "$CONFIG_FILE")"
fi

UC_ACCESS_TOKEN="${UNITY_CATALOG_ADMIN_TOKEN:-${UC_ACCESS_TOKEN:-}}"
if [[ -z "$UC_ACCESS_TOKEN" ]]; then
  UC_ACCESS_TOKEN="$(yq e '.unity_catalog.admin_token' "$CONFIG_FILE")"
fi

for required in MINIO_ROOT_PASSWORD GRAFANA_ADMIN_PASSWORD UC_ACCESS_TOKEN; do
  if [[ -z "${!required}" || "${!required}" == "CHANGEME" ]]; then
    echo "ERROR: Required secret '$required' is missing."
    echo "Set it in your shell environment before running deploy/deploy-node.sh"
    exit 1
  fi
done

TRINO_VALUES_RENDERED="$(mktemp)"
trap 'rm -f "$TRINO_VALUES_RENDERED"' EXIT
sed "s|<your-uc-access-token>|${UC_ACCESS_TOKEN}|g" config/values/trino-values.yaml > "$TRINO_VALUES_RENDERED"

echo "🚀 Initiating Public Health AI Node Deployment..."

# 1. Gateway
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-basic --create-namespace \
  -f config/values/ingress-values.yaml

# 2. Monitoring Stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f config/values/monitoring-values.yaml \
  --set-string grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD"

# 3. Storage
helm upgrade --install minio bitnami/minio \
  --namespace "$NAMESPACE" --create-namespace \
  --set-string auth.rootUser="$MINIO_ROOT_USER" \
  --set-string auth.rootPassword="$MINIO_ROOT_PASSWORD" \
  --set-string defaultBuckets="$(yq e '.minio.buckets | join(",")' "$CONFIG_FILE")"

# 4. Metadata
if [[ -d "./charts/unity-catalog" ]]; then
  helm upgrade --install unity-catalog ./charts/unity-catalog \
    --namespace "$NAMESPACE"
else
  echo "WARN: ./charts/unity-catalog not found; skipping Unity Catalog Helm release."
fi

# 5. Compute
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace "$NAMESPACE" \
  -f config/values/spark-values.yaml
helm upgrade --install trino trino/trino \
  --namespace "$NAMESPACE" \
  -f "$TRINO_VALUES_RENDERED"

# 6. Orchestration
helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE"

# 7. ML & Workspace
if [[ -d "./charts/mlflow" ]]; then
  helm upgrade --install mlflow ./charts/mlflow \
    --namespace "$NAMESPACE"
else
  echo "WARN: ./charts/mlflow not found; skipping MLflow Helm release."
fi
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace "$NAMESPACE" \
  -f config/values/jupyterhub-values.yaml \
  --set-string ingress.hosts[0]="jupyter.${DOMAIN}"

# 8. Serving
# Download and apply KServe manifest (pinned version v0.11.0)
KSERVE_MANIFEST="deploy/kserve-v0.11.0.yaml"
if [ ! -f "$KSERVE_MANIFEST" ]; then
  curl -fsSL https://github.com/kserve/kserve/releases/download/v0.11.0/kserve.yaml -o "$KSERVE_MANIFEST"
fi
kubectl apply -f "$KSERVE_MANIFEST"

echo "✅ Deployment Complete! Node is ready."
