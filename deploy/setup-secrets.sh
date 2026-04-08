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

AIRFLOW_SECRET_NAME="airflow-secrets"
AIRFLOW_FERNET_KEY="${AIRFLOW_FERNET_KEY:-}"
AIRFLOW_WEBSERVER_SECRET_KEY="${AIRFLOW_WEBSERVER_SECRET_KEY:-}"
AIRFLOW_ADMIN_PASSWORD="${AIRFLOW_ADMIN_PASSWORD:-}"
AIRFLOW_SQL_ALCHEMY_CONN="${AIRFLOW_SQL_ALCHEMY_CONN:-}"

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

if [[ -z "$AIRFLOW_SQL_ALCHEMY_CONN" ]]; then
  POSTGRES_APP_USER="$(yq e '.postgres.appUser' "$CONFIG_FILE")"
  POSTGRES_DB="$(yq e '.postgres.database' "$CONFIG_FILE")"
  ENCODED_POSTGRES_USER="$(jq -nr --arg value "$POSTGRES_APP_USER" '$value|@uri')"
  ENCODED_POSTGRES_PASSWORD="$(jq -nr --arg value "$POSTGRES_APP_PASSWORD" '$value|@uri')"
  AIRFLOW_SQL_ALCHEMY_CONN="postgresql+psycopg2://${ENCODED_POSTGRES_USER}:${ENCODED_POSTGRES_PASSWORD}@pgbouncer.${NAMESPACE}.svc.cluster.local:5432/${POSTGRES_DB}"
fi

if [[ -n "$AIRFLOW_FERNET_KEY" && -n "$AIRFLOW_WEBSERVER_SECRET_KEY" && -n "$AIRFLOW_ADMIN_PASSWORD" ]]; then
  kubectl create secret generic "$AIRFLOW_SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --from-literal=sql_alchemy_conn="$AIRFLOW_SQL_ALCHEMY_CONN" \
    --from-literal=fernet_key="$AIRFLOW_FERNET_KEY" \
    --from-literal=webserver_secret_key="$AIRFLOW_WEBSERVER_SECRET_KEY" \
    --from-literal=admin_password="$AIRFLOW_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
elif kubectl get secret "$AIRFLOW_SECRET_NAME" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "  -> Reusing existing $AIRFLOW_SECRET_NAME secret (external secret manager or prior setup)"
else
  echo "ERROR: Airflow secret '$AIRFLOW_SECRET_NAME' is missing."
  echo "Set AIRFLOW_FERNET_KEY, AIRFLOW_WEBSERVER_SECRET_KEY, and AIRFLOW_ADMIN_PASSWORD before running this script"
  echo "or provision the '$AIRFLOW_SECRET_NAME' secret externally (for example via Vault or External Secrets)."
  exit 1
fi

echo "✅ Secrets provisioned."
