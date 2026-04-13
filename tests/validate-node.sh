#!/bin/bash
set -euo pipefail

CONFIG_FILE="config/env-config.yaml"
NAMESPACE="$(yq e '.global.namespace' "$CONFIG_FILE")"
POSTGRES_DB="$(yq e '.postgres.database' "$CONFIG_FILE")"
POSTGRES_APP_USER="$(yq e '.postgres.appUser' "$CONFIG_FILE")"

echo "🔍 Testing Lakehouse Connectivity..."

kubectl exec deployment/minio -- mc ls local/
echo "SELECT count(*) FROM iceberg.system.snapshots;" | trino-cli --server trino.data-stack:8080

echo ""
echo "🔍 Testing portless dev proxy..."
if ! command -v portless &>/dev/null; then
  echo "  [WARN] portless not installed — run deploy/bootstrap.sh"
else
  portless proxy status 2>/dev/null && echo "  -> portless proxy: running" \
    || echo "  [WARN] portless proxy not running — run: bash deploy/dev-proxy.sh"

  # Smoke-check that at least one named route resolves
  if curl -sf --max-time 3 "http://grafana.dakar-datasphere-node.localhost:1355" -o /dev/null; then
    echo "  -> grafana.dakar-datasphere-node.localhost:1355: reachable"
  else
    echo "  [WARN] grafana route not reachable — run: bash deploy/dev-proxy.sh"
  fi
fi

echo ""
echo "🔍 Testing PostgreSQL + PgBouncer..."
kubectl get statefulset postgresql -n "$NAMESPACE" >/dev/null
echo "  -> postgresql statefulset: present"

kubectl get deployment pgbouncer -n "$NAMESPACE" >/dev/null
echo "  -> pgbouncer deployment: present"

kubectl get cronjob postgres-backup -n "$NAMESPACE" >/dev/null
echo "  -> postgres-backup cronjob: present"

kubectl get pvc postgres-backups -n "$NAMESPACE" >/dev/null
echo "  -> postgres-backups pvc: present"

POSTGRES_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=primary,app.kubernetes.io/instance=postgresql -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$POSTGRES_POD" ]]; then
  echo "  [WARN] could not resolve postgres primary pod"
else
  POSTGRES_APP_PASSWORD="$(kubectl get secret postgres-creds -n "$NAMESPACE" -o jsonpath='{.data.app-password}' | base64 -d)"
  EXTENSIONS="$(kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- sh -c "PGPASSWORD='$POSTGRES_APP_PASSWORD' psql -U '$POSTGRES_APP_USER' -d '$POSTGRES_DB' -Atc \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','vector') ORDER BY extname;\"" || true)"

  if [[ "$EXTENSIONS" == *"postgis"* && "$EXTENSIONS" == *"vector"* ]]; then
    echo "  -> extensions enabled: postgis, vector"
  else
    echo "  [WARN] expected extensions postgis/vector not fully detected"
  fi
fi

LATEST_BACKUP_JOB="$(kubectl get jobs -n "$NAMESPACE" -l cronjob-name=postgres-backup -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [[ -n "$LATEST_BACKUP_JOB" ]]; then
  echo "  -> latest backup job detected: $LATEST_BACKUP_JOB"
else
  echo "  [WARN] no completed postgres backup job detected yet; trigger one manually after deploy if needed"
fi

echo ""
echo "✅ Node is healthy and integrated."
