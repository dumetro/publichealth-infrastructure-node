#!/bin/bash
set -e

CONFIG_FILE="config/env-config.yaml"
NAMESPACE=$(yq e '.global.namespace' $CONFIG_FILE)

# ---- Preflight: verify required Helm repos are registered ----
REQUIRED_REPOS=(
  ingress-nginx
  prometheus-community
  bitnami
  spark-operator
  trino
  apache-airflow
  jupyterhub
)

MISSING_REPOS=()
for REPO in "${REQUIRED_REPOS[@]}"; do
  if ! helm repo list 2>/dev/null | grep -q "^${REPO}[[:space:]]"; then
    MISSING_REPOS+=("$REPO")
  fi
done

if [[ ${#MISSING_REPOS[@]} -gt 0 ]]; then
  echo "⚠️  Preflight check failed — missing Helm repositories: ${MISSING_REPOS[*]}"
  echo "   Running deploy/bootstrap.sh to install prerequisites..."
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ $EUID -ne 0 ]]; then
    echo "   bootstrap.sh requires root. Re-running with sudo..."
    sudo bash "$SCRIPT_DIR/bootstrap.sh" || {
      echo "ERROR: bootstrap.sh failed. Please fix the errors above and re-run deploy/deploy-node.sh."
      exit 1
    }
  else
    bash "$SCRIPT_DIR/bootstrap.sh" || {
      echo "ERROR: bootstrap.sh failed. Please fix the errors above and re-run deploy/deploy-node.sh."
      exit 1
    }
  fi
  echo "   Bootstrap complete. Resuming deployment..."
fi

echo "🚀 Initiating Public Health AI Node Deployment..."

# 1. Gateway
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-basic --create-namespace \
  -f config/values/ingress-values.yaml

# 2. Monitoring Stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f config/values/monitoring-values.yaml

# 3. Storage
helm upgrade --install minio bitnami/minio \
  --namespace $NAMESPACE \
  -f $CONFIG_FILE \
  --set defaultBuckets=$(yq e '.minio.buckets | join(",")' $CONFIG_FILE)

# 4. Metadata
helm upgrade --install unity-catalog ./charts/unity-catalog \
  --namespace $NAMESPACE \
  -f $CONFIG_FILE

# 5. Compute
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace $NAMESPACE
helm upgrade --install trino trino/trino \
  --namespace $NAMESPACE \
  -f $CONFIG_FILE \
  -f config/values/trino-values.yaml

# 6. Orchestration
helm upgrade --install airflow apache-airflow/airflow \
  --namespace $NAMESPACE \
  -f $CONFIG_FILE

# 7. ML & Workspace
helm upgrade --install mlflow ./charts/mlflow \
  --namespace $NAMESPACE \
  -f $CONFIG_FILE
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace $NAMESPACE \
  -f config/values/jupyterhub-values.yaml \
  -f $CONFIG_FILE

# 8. Serving
# Download and apply KServe manifest (pinned version v0.11.0)
KSERVE_MANIFEST="deploy/kserve-v0.11.0.yaml"
if [ ! -f "$KSERVE_MANIFEST" ]; then
  curl -fsSL https://github.com/kserve/kserve/releases/download/v0.11.0/kserve.yaml -o "$KSERVE_MANIFEST"
fi
kubectl apply -f "$KSERVE_MANIFEST"

echo "✅ Deployment Complete! Node is ready."
