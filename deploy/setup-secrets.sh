#!/bin/bash
set -euo pipefail

CONFIG_FILE="config/env-config.yaml"
NAMESPACE=$(yq e '.global.namespace' "$CONFIG_FILE")
MINIO_USER="${MINIO_ROOT_USER:-$(yq e '.minio.rootUser' "$CONFIG_FILE")}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-}"
if [[ -z "$MINIO_PASS" ]]; then
  MINIO_PASS="$(yq e '.minio.rootPassword' "$CONFIG_FILE")"
fi

UC_TOKEN="${UNITY_CATALOG_ADMIN_TOKEN:-}"
if [[ -z "$UC_TOKEN" ]]; then
  UC_TOKEN="$(yq e '.unity_catalog.admin_token' "$CONFIG_FILE")"
fi

for required in MINIO_PASS UC_TOKEN; do
  if [[ -z "${!required}" || "${!required}" == "CHANGEME" ]]; then
    echo "ERROR: Required secret '$required' is missing."
    echo "Set MINIO_ROOT_PASSWORD and UNITY_CATALOG_ADMIN_TOKEN environment variables."
    exit 1
  fi
done

echo "🔐 Provisioning Secrets for namespace: $NAMESPACE..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic minio-creds \
  --namespace "$NAMESPACE" \
  --from-literal=access-key="$MINIO_USER" \
  --from-literal=secret-key="$MINIO_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic unity-catalog-creds \
  --namespace "$NAMESPACE" \
  --from-literal=access-token="$UC_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets provisioned."
