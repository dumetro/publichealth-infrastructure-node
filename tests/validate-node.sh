#!/bin/bash
set -euo pipefail

CONFIG_FILE="config/env-config.yaml"
NAMESPACE="$(yq e '.global.namespace' "$CONFIG_FILE")"
POSTGRES_DB="$(yq e '.postgres.database' "$CONFIG_FILE")"
POSTGRES_APP_USER="$(yq e '.postgres.appUser' "$CONFIG_FILE")"
AIRFLOW_HOST="$(yq e '.airflow.hostname' "$CONFIG_FILE")"
MINIO_HOST="$(yq e '.minio.hostname' "$CONFIG_FILE")"
JUPYTER_HOST="$(yq e '.jupyterhub.hostname' "$CONFIG_FILE")"
GRAFANA_HOST="$(yq e '.monitoring.grafana.domain' "$CONFIG_FILE")"
DOMAIN="$(yq e '.global.domain' "$CONFIG_FILE")"
MINIO_CONSOLE_HOST="console.${DOMAIN}"

ERRORS=0
WARNINGS=0

check_status() {
  local name="$1"
  local namespace="$2"
  local selector="$3"
  local expected_ready="$4"

  local ready=$(kubectl get pods -n "$namespace" -l "$selector" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)

  if [[ $ready -ge $expected_ready ]]; then
    echo "  ✓ $name: $ready/$expected_ready pods ready"
  else
    echo "  ✗ $name: only $ready/$expected_ready pods ready"
    ((ERRORS++))
  fi
}

check_resource() {
  local type="$1"
  local name="$2"
  local namespace="$3"

  if kubectl get "$type" "$name" -n "$namespace" >/dev/null 2>&1; then
    echo "  ✓ $type/$name: exists"
  else
    echo "  ✗ $type/$name: missing"
    ((ERRORS++))
  fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "🔍 Public Health AI Node Deployment Validation"
echo "═══════════════════════════════════════════════════════════════"

# Step 1: Monitoring Stack
echo ""
echo "📊 Step 1: Monitoring Stack"
check_status "Prometheus" "monitoring" "app.kubernetes.io/name=prometheus" 1
check_status "Grafana" "monitoring" "app.kubernetes.io/name=grafana" 1
check_status "AlertManager" "monitoring" "app.kubernetes.io/name=alertmanager" 1

GRAFANA_READY=$(kubectl get pods -n "monitoring" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
if [[ "$GRAFANA_READY" == "True" ]]; then
  echo "  ✓ Grafana: web UI accessible (dashboards available)"
else
  echo "  ℹ Grafana: starting up"
fi

# Step 2: Ingress Gateway
echo ""
echo "🚪 Step 2: Ingress Gateway"
check_status "ingress-nginx" "ingress-basic" "app.kubernetes.io/name=ingress-nginx" 1

# Step 3: MinIO Storage
echo ""
echo "💾 Step 3: MinIO Storage"
check_status "MinIO" "$NAMESPACE" "app.kubernetes.io/instance=minio" 1
MINIO_PVC=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/instance=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$MINIO_PVC" ]]; then
  SIZE=$(kubectl get pvc "$MINIO_PVC" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
  echo "  ✓ MinIO PVC: $MINIO_PVC ($SIZE)"
else
  echo "  ✗ MinIO PVC: not found"
  ((ERRORS++))
fi

# Step 4: Database + PgBouncer + Backups
echo ""
echo "🗄️  Step 4: PostgreSQL + PgBouncer + Backups"
check_status "PostgreSQL" "$NAMESPACE" "app=postgresql" 1
check_status "PgBouncer" "$NAMESPACE" "app=pgbouncer" 2
check_resource "cronjob" "postgres-backup" "$NAMESPACE"
check_resource "pvc" "postgres-backups" "$NAMESPACE"

POSTGRES_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=primary,app.kubernetes.io/instance=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$POSTGRES_POD" ]]; then
  POSTGRES_APP_PASSWORD="$(kubectl get secret postgres-creds -n "$NAMESPACE" -o jsonpath='{.data.app-password}' | base64 -d 2>/dev/null || true)"
  if [[ -n "$POSTGRES_APP_PASSWORD" ]]; then
    EXTENSIONS="$(kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- sh -c "PGPASSWORD='$POSTGRES_APP_PASSWORD' psql -U '$POSTGRES_APP_USER' -d '$POSTGRES_DB' -Atc \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','vector') ORDER BY extname;\"" 2>/dev/null || true)"

    if [[ "$EXTENSIONS" == *"postgis"* && "$EXTENSIONS" == *"vector"* ]]; then
      echo "  ✓ Extensions: postgis, vector enabled"
    else
      echo "  ⚠ Extensions: postgis/vector not fully enabled (expected but not critical)"
      ((WARNINGS++))
    fi
  fi
fi

# Step 5: Metadata (Unity Catalog - optional)
echo ""
echo "📋 Step 5: Metadata Layer (Unity Catalog - optional)"
if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/instance=unity-catalog >/dev/null 2>&1; then
  check_status "Unity Catalog" "$NAMESPACE" "app.kubernetes.io/instance=unity-catalog" 1
else
  echo "  ⓘ Unity Catalog: not deployed (optional)"
fi

# Step 6: Compute
echo ""
echo "⚙️  Step 6: Compute Layer"
check_status "Spark Operator Controller" "$NAMESPACE" "app.kubernetes.io/instance=spark-operator,app.kubernetes.io/component=controller" 1
check_status "Spark Operator Webhook" "$NAMESPACE" "app.kubernetes.io/instance=spark-operator,app.kubernetes.io/component=webhook" 1
check_status "Trino Coordinator" "$NAMESPACE" "app.kubernetes.io/instance=trino,app.kubernetes.io/component=coordinator" 1
TRINO_WORKERS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=trino,app.kubernetes.io/component=worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
if [[ $TRINO_WORKERS -gt 0 ]]; then
  echo "  ✓ Trino Workers: $TRINO_WORKERS deployed"
else
  echo "  ⚠ Trino Workers: none ready (expected at startup)"
  ((WARNINGS++))
fi

# Step 7: Orchestration (Airflow)
echo ""
echo "🔄 Step 7: Orchestration (Airflow)"
if kubectl get release airflow -n "$NAMESPACE" >/dev/null 2>&1; then
  AIRFLOW_READY=$(kubectl get pods -n "$NAMESPACE" -l release=airflow -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo 0)
  AIRFLOW_TOTAL=$(kubectl get pods -n "$NAMESPACE" -l release=airflow --no-headers 2>/dev/null | wc -l)
  echo "  ℹ Airflow pods: $AIRFLOW_READY/$AIRFLOW_TOTAL ready (migrations may still be running)"

  MIGRATION_JOB=$(kubectl get pods -n "$NAMESPACE" -l 'job-name=airflow-run-airflow-migrations' -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "not-found")
  if [[ "$MIGRATION_JOB" == "Succeeded" ]]; then
    echo "  ✓ Airflow migrations: completed"
  elif [[ "$MIGRATION_JOB" == "Running" ]]; then
    echo "  ℹ Airflow migrations: in progress"
  else
    echo "  ⚠ Airflow migrations: not started or unknown state"
    ((WARNINGS++))
  fi

  WEBSERVER_READY=$(kubectl get pods -n "$NAMESPACE" -l release=airflow,component=webserver -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
  if [[ "$WEBSERVER_READY" == "True" ]]; then
    echo "  ✓ Airflow webserver: ready (UI accessible)"
  else
    echo "  ℹ Airflow webserver: starting up"
  fi
else
  echo "  ✗ Airflow: not deployed"
  ((ERRORS++))
fi

# Step 8: ML & Workspace (JupyterHub + MLflow)
echo ""
echo "🧪 Step 8: ML & Workspace"
check_status "JupyterHub Hub" "$NAMESPACE" "app.kubernetes.io/instance=jupyterhub,app.kubernetes.io/component=hub" 1
check_status "JupyterHub Proxy" "$NAMESPACE" "app.kubernetes.io/instance=jupyterhub,app.kubernetes.io/component=proxy" 1

HUB_READY=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=jupyterhub,app.kubernetes.io/component=hub -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
if [[ "$HUB_READY" == "True" ]]; then
  echo "  ✓ JupyterHub: web UI accessible"
else
  echo "  ℹ JupyterHub: starting up"
fi

if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/instance=mlflow >/dev/null 2>&1; then
  check_status "MLflow" "$NAMESPACE" "app.kubernetes.io/instance=mlflow" 1
else
  echo "  ⓘ MLflow: not deployed (optional)"
fi

# Step 9: Serving (KServe)
echo ""
echo "🚀 Step 9: Model Serving (KServe)"
if kubectl get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then
  check_status "KServe Controller" "kserve" "app.kubernetes.io/instance=kserve" 1
  echo "  ✓ KServe: CRDs and controller present"
else
  echo "  ⚠ KServe: CRDs not found (manifest may not have applied)"
  ((WARNINGS++))
fi

# Step 10: Ingresses
echo ""
echo "🌐 Step 10: Service Ingresses"
check_resource "ingress" "airflow-api-server" "$NAMESPACE"
check_resource "ingress" "jupyterhub" "$NAMESPACE"
check_resource "ingress" "minio-api" "$NAMESPACE"
check_resource "ingress" "minio-console" "$NAMESPACE"

# Service Endpoints
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📍 Service Endpoints"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "PostgreSQL (Internal):"
echo "  Connection: postgresql.${NAMESPACE}.svc.cluster.local:5432"
echo "  Database: $POSTGRES_DB"
echo "  App User: $POSTGRES_APP_USER"
echo "  Via PgBouncer: pgbouncer.${NAMESPACE}.svc.cluster.local:5432"
echo ""
echo "MinIO S3 API:"
echo "  Endpoint: http://${MINIO_HOST}:9000"
echo "  Access Key: (see secret: kubectl get secret minio -n $NAMESPACE -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Secret Key: (see secret: kubectl get secret minio -n $NAMESPACE -o jsonpath='{.data.root-password}' | base64 -d)"
echo ""
echo "MinIO Console (built-in to server):"
echo "  URL: http://${MINIO_CONSOLE_HOST}"
echo "  Login: same credentials as MinIO S3 API (root user/password above)"
echo "  Features: Bucket creation, file upload, access policies, metrics"
echo ""
echo "Airflow Webserver & Console:"
echo "  URL: http://${AIRFLOW_HOST}"
echo "  Admin User: admin"
echo "  Admin Password: (from airflow-secrets secret, key: admin_password)"
echo "    Get it: kubectl get secret airflow-secrets -n $NAMESPACE -o jsonpath='{.data.admin_password}' | base64 -d"
echo "  Features:"
echo "    - DAG management & visualization"
echo "    - Workflow monitoring & logs"
echo "    - Task scheduling & execution"
echo ""
echo "JupyterHub Workspace:"
echo "  URL: http://${JUPYTER_HOST}"
echo "  Admin User: admin"
echo "  Password: (from config/values/jupyterhub-values.yaml, hub.config.DummyAuthenticator.password)"
echo "  Features:"
echo "    - Multi-user Jupyter notebooks"
echo "    - Pre-configured kernels (Python, SQL, etc.)"
echo "    - Direct access to PostgreSQL, MinIO, MLflow, Spark"
echo "    - Persistent home directories per user"
echo "    - Profile selection (Standard 1CPU/2GB, Large 2CPU/4GB)"
echo ""
echo "Grafana Monitoring & Dashboards:"
echo "  URL: http://${GRAFANA_HOST}"
echo "  Admin User: admin"
echo "  Admin Password: (from GRAFANA_ADMIN_PASSWORD environment variable)"
echo "    Get it: kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
echo "  Data Sources:"
echo "    - Prometheus (cluster metrics, node stats, pod performance)"
echo "    - AlertManager (alerts & notifications)"
echo "  Pre-built Dashboards:"
echo "    - Kubernetes cluster overview"
echo "    - Pod & container resource usage"
echo "    - Network I/O & latency"
echo "    - Node memory/CPU pressure"
echo ""

# Summary
echo "═══════════════════════════════════════════════════════════════"
if [[ $ERRORS -eq 0 ]]; then
  echo "✅ Validation Complete"
  if [[ $WARNINGS -gt 0 ]]; then
    echo "   ($WARNINGS non-critical warnings)"
  else
    echo "   All checks passed!"
  fi
else
  echo "❌ Validation Failed: $ERRORS error(s), $WARNINGS warning(s)"
  exit 1
fi
echo "═══════════════════════════════════════════════════════════════"
