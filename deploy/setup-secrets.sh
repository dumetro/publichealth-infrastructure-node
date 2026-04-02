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

POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}"
if [[ -z "$POSTGRES_SUPERUSER_PASSWORD" ]]; then
  POSTGRES_SUPERUSER_PASSWORD="$(yq e '.postgres.superuserPassword' "$CONFIG_FILE")"
fi

POSTGRES_APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"
if [[ -z "$POSTGRES_APP_PASSWORD" ]]; then
  POSTGRES_APP_PASSWORD="$(yq e '.postgres.appPassword' "$CONFIG_FILE")"
fi

for required in MINIO_PASS UC_TOKEN POSTGRES_SUPERUSER_PASSWORD POSTGRES_APP_PASSWORD; do
  if [[ -z "${!required}" || "${!required}" == "CHANGEME" ]]; then
    echo "ERROR: Required secret '$required' is missing."
    echo "Set MINIO_ROOT_PASSWORD, UNITY_CATALOG_ADMIN_TOKEN, POSTGRES_SUPERUSER_PASSWORD, and POSTGRES_APP_PASSWORD."
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

kubectl create secret generic postgres-creds \
  --namespace "$NAMESPACE" \
  --from-literal=postgres-password="$POSTGRES_SUPERUSER_PASSWORD" \
  --from-literal=app-password="$POSTGRES_APP_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets provisioned."
