#!/bin/bash
set -e

NAMESPACE=$(yq e '.global.namespace' config/env-config.yaml)
MINIO_USER=$(yq e '.minio.rootUser' config/env-config.yaml)
MINIO_PASS=$(yq e '.minio.rootPassword' config/env-config.yaml)
UC_TOKEN=$(yq e '.unity_catalog.admin_token' config/env-config.yaml)

echo "🔐 Provisioning Secrets for namespace: $NAMESPACE..."

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic minio-creds \
  --namespace $NAMESPACE \
  --from-literal=access-key="$MINIO_USER" \
  --from-literal=secret-key="$MINIO_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic unity-catalog-creds \
  --namespace $NAMESPACE \
  --from-literal=access-token="$UC_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets provisioned."
