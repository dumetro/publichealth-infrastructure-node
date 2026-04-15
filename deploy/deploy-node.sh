#!/bin/bash
set -euo pipefail

CONFIG_FILE="config/env-config.yaml"
NAMESPACE=$(yq e '.global.namespace' "$CONFIG_FILE")
DOMAIN=$(yq e '.global.domain' "$CONFIG_FILE")
JUPYTER_HOST=$(yq e '.jupyterhub.hostname' "$CONFIG_FILE")
STORAGE_CLASS=$(yq e '.global.storageClass' "$CONFIG_FILE")

POSTGRES_IMAGE_REPOSITORY=$(yq e '.postgres.image.repository' "$CONFIG_FILE")
POSTGRES_IMAGE_TAG=$(yq e '.postgres.image.tag' "$CONFIG_FILE")
POSTGRES_DB=$(yq e '.postgres.database' "$CONFIG_FILE")
POSTGRES_APP_USER=$(yq e '.postgres.appUser' "$CONFIG_FILE")
POSTGRES_PERSISTENCE_SIZE=$(yq e '.postgres.persistence.size' "$CONFIG_FILE")
POSTGRES_BACKUP_SCHEDULE=$(yq e '.postgres.backup.schedule' "$CONFIG_FILE")
POSTGRES_BACKUP_RETENTION_DAYS=$(yq e '.postgres.backup.retentionDays' "$CONFIG_FILE")
POSTGRES_BACKUP_HISTORY_LIMIT=$(yq e '.postgres.backup.historyLimit' "$CONFIG_FILE")
POSTGRES_BACKUP_PVC_SIZE=$(yq e '.postgres.backup.pvcSize' "$CONFIG_FILE")

PGBOUNCER_POOL_MODE=$(yq e '.pgbouncer.poolMode' "$CONFIG_FILE")
PGBOUNCER_MAX_CLIENT_CONN=$(yq e '.pgbouncer.maxClientConn' "$CONFIG_FILE")
PGBOUNCER_DEFAULT_POOL_SIZE=$(yq e '.pgbouncer.defaultPoolSize' "$CONFIG_FILE")
PGBOUNCER_RESERVE_POOL_SIZE=$(yq e '.pgbouncer.reservePoolSize' "$CONFIG_FILE")

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

POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}"
if [[ -z "$POSTGRES_SUPERUSER_PASSWORD" ]]; then
  POSTGRES_SUPERUSER_PASSWORD="$(yq e '.postgres.superuserPassword' "$CONFIG_FILE")"
fi

POSTGRES_APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"
if [[ -z "$POSTGRES_APP_PASSWORD" ]]; then
  POSTGRES_APP_PASSWORD="$(yq e '.postgres.appPassword' "$CONFIG_FILE")"
fi

for required in POSTGRES_SUPERUSER_PASSWORD POSTGRES_APP_PASSWORD; do
  if [[ -z "${!required}" || "${!required}" == "CHANGEME" ]]; then
    echo "ERROR: Required secret '$required' is missing."
    echo "Set it in your shell environment before running deploy/deploy-node.sh"
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to render URI-safe Airflow metadata credentials."
  echo "Install it via deploy/bootstrap.sh before running deploy/deploy-node.sh"
  exit 1
fi

TRINO_VALUES_RENDERED="$(mktemp)"
GRAFANA_SECRET_VALUES="$(mktemp)"
MINIO_SECRET_VALUES="$(mktemp)"
POSTGRES_SECRET_VALUES="$(mktemp)"
trap 'rm -f "$TRINO_VALUES_RENDERED" "$GRAFANA_SECRET_VALUES" "$MINIO_SECRET_VALUES" "$POSTGRES_SECRET_VALUES"' EXIT

UC_ACCESS_TOKEN="$UC_ACCESS_TOKEN" envsubst '${UC_ACCESS_TOKEN}' < config/values/trino-values.yaml > "$TRINO_VALUES_RENDERED"

# Write secret values to temp YAML files using yq so any special characters
# (commas, braces, backslashes, quotes) are safely encoded.
# --set-string splits on commas and chokes on {}/[] — a -f values file has no such limits.
yq e -n \
  '.grafana.adminPassword = strenv("GRAFANA_ADMIN_PASSWORD")' \
  > "$GRAFANA_SECRET_VALUES"

yq e -n \
  '.auth.rootPassword     = strenv("MINIO_ROOT_PASSWORD") |
   .auth.usePasswordFiles = false |
   .console.enabled       = false |
   .command               = ["minio"] |
   .args                  = ["server", "/bitnami/minio/data"]' \
  > "$MINIO_SECRET_VALUES"

yq e -n \
  '.auth.postgresPassword = strenv("POSTGRES_SUPERUSER_PASSWORD") |
   .auth.password         = strenv("POSTGRES_APP_PASSWORD")' \
  > "$POSTGRES_SECRET_VALUES"

echo "🚀 Initiating Public Health AI Node Deployment..."

# 1. Monitoring Stack — deployed first so Prometheus Operator CRDs (ServiceMonitor etc.)
# are available before ingress-nginx tries to create a ServiceMonitor resource.
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f config/values/monitoring-values.yaml \
  -f "$GRAFANA_SECRET_VALUES"

# 2. Gateway — depends on ServiceMonitor CRD from step 1.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-basic --create-namespace \
  -f config/values/ingress-values.yaml

# 3. Storage
# Bitnami minio images require a paid subscription since Aug 2025 — override with the
# official quay.io/minio/minio image which is freely available.
# This chart version still defaults to a separate console image that is no longer
# published, so disable that deployment and run the upstream server with explicit
# arguments instead of the Bitnami entrypoint contract.
helm upgrade --install minio bitnami/minio \
  --namespace "$NAMESPACE" --create-namespace \
  --set global.security.allowInsecureImages=true \
  --set-string image.registry="quay.io" \
  --set-string image.repository="minio/minio" \
  --set-string image.tag="RELEASE.2025-09-07T16-13-09Z" \
  --set-string clientImage.registry="quay.io" \
  --set-string clientImage.repository="minio/mc" \
  --set-string clientImage.tag="latest" \
  --set-string auth.rootUser="$MINIO_ROOT_USER" \
  -f "$MINIO_SECRET_VALUES" \
  --wait --timeout 10m
# NOTE: The upstream MinIO image bundles the web console, but this Bitnami chart
# still tries to deploy an obsolete standalone browser image by default. We disable
# that console deployment above to keep the release functional.
# NOTE: Buckets are not created automatically at deploy time.
# Create them manually after deploy: mc mb local/raw local/standard local/published

if ! kubectl rollout status deployment/minio -n "$NAMESPACE" --timeout=10m; then
  echo ""
  echo "ERROR: MinIO deployment did not become ready within 10m. Diagnostics:"
  echo ""
  echo "--- Pod status ---"
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=minio -o wide || true
  echo ""
  echo "--- Pod events ---"
  MINIO_POD_DIAG="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=minio,app.kubernetes.io/instance=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$MINIO_POD_DIAG" ]]; then
    kubectl describe pod "$MINIO_POD_DIAG" -n "$NAMESPACE" || true
    echo ""
    echo "--- Container logs ---"
    kubectl logs "$MINIO_POD_DIAG" -n "$NAMESPACE" --tail=80 || true
    echo ""
    echo "--- Previous container logs ---"
    kubectl logs "$MINIO_POD_DIAG" -n "$NAMESPACE" --previous --tail=80 || true
  else
    echo "  (no MinIO pod found)"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
  fi
  exit 1
fi

# 4. Database — deployed as a plain StatefulSet using our custom postgis+pgvector image.
# The Bitnami postgresql chart expects Bitnami-specific entrypoints that are not present
# in postgis/postgis-based images, causing init containers to crash and rollout to time out.
#
# Delete any existing postgresql StatefulSet before applying — Kubernetes forbids in-place
# updates to volumeClaimTemplates and selector fields (e.g. leftover from a failed Bitnami
# install). The PVC is preserved so data survives across re-deploys.
if kubectl get statefulset postgresql -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "  -> Removing existing postgresql StatefulSet (PVC preserved)..."
  kubectl delete statefulset postgresql -n "$NAMESPACE" --cascade=orphan
fi
# Also delete the orphaned pod so the new StatefulSet creates a clean one.
# --cascade=orphan leaves the pod running; it may reference stale Bitnami ConfigMaps
# that no longer exist (e.g. postgresql-extended-configuration deleted by helm uninstall).
kubectl delete pod postgresql-0 -n "$NAMESPACE" --ignore-not-found=true
# Uninstall any leftover Bitnami helm release for postgresql
helm uninstall postgresql -n "$NAMESPACE" 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: postgresql
  ports:
    - port: 5432
      targetPort: 5432
      name: postgresql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: ${NAMESPACE}
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
      app.kubernetes.io/component: primary
      app.kubernetes.io/instance: postgresql
  template:
    metadata:
      labels:
        app: postgresql
        app.kubernetes.io/component: primary
        app.kubernetes.io/instance: postgresql
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: postgresql
          image: ${POSTGRES_IMAGE_REPOSITORY}:${POSTGRES_IMAGE_TAG}
          imagePullPolicy: Never
          env:
            - name: POSTGRES_DB
              value: ${POSTGRES_DB}
            - name: POSTGRES_USER
              value: postgres
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-creds
                  key: postgres-password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 2Gi
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: postgresql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${POSTGRES_PERSISTENCE_SIZE}
EOF

if ! kubectl rollout status statefulset/postgresql -n "$NAMESPACE" --timeout=10m; then
  echo ""
  echo "ERROR: PostgreSQL StatefulSet did not become ready within 10m. Diagnostics:"
  echo ""
  echo "--- Pod status ---"
  kubectl get pods -n "$NAMESPACE" -l app=postgresql -o wide || true
  echo ""
  echo "--- Pod events ---"
  POSTGRES_POD_DIAG="$(kubectl get pod -n "$NAMESPACE" -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$POSTGRES_POD_DIAG" ]]; then
    kubectl describe pod "$POSTGRES_POD_DIAG" -n "$NAMESPACE" || true
    echo ""
    echo "--- Container logs ---"
    kubectl logs "$POSTGRES_POD_DIAG" -n "$NAMESPACE" --all-containers --tail=60 || true
  else
    echo "  (no pod found — StatefulSet may have failed to schedule)"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
  fi
  exit 1
fi

POSTGRES_POD="$(kubectl get pod -n "$NAMESPACE" -l app=postgresql -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$POSTGRES_POD" ]]; then
  echo "ERROR: Unable to find PostgreSQL primary pod"
  exit 1
fi

# Create app user, grant privileges, and enable extensions.
# Write a temporary SQL file into the pod to avoid shell quoting complexity with passwords.
PGPASSWORD_SUPERUSER="$(kubectl get secret postgres-creds -n "$NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)"
PGPASSWORD_APP="$(kubectl get secret postgres-creds -n "$NAMESPACE" -o jsonpath='{.data.app-password}' | base64 -d)"
PGPASSWORD_APP_SQL_ESCAPED="${PGPASSWORD_APP//\'/\'\'}"

if [[ "$POSTGRES_APP_PASSWORD" != "$PGPASSWORD_APP" ]]; then
  echo "WARN: POSTGRES_APP_PASSWORD differs from the live postgres-creds secret."
  echo "      Using the cluster secret value for PgBouncer and Airflow to keep auth consistent."
  echo "      Re-run deploy/setup-secrets.sh first if you intended to rotate database credentials."
fi

TMP_INIT_SQL="$(mktemp)"
trap 'rm -f "$TRINO_VALUES_RENDERED" "$GRAFANA_SECRET_VALUES" "$MINIO_SECRET_VALUES" "$POSTGRES_SECRET_VALUES" "$TMP_INIT_SQL"' EXIT
cat > "$TMP_INIT_SQL" <<ENDSQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_APP_USER}') THEN
    CREATE USER "${POSTGRES_APP_USER}" WITH PASSWORD '${PGPASSWORD_APP_SQL_ESCAPED}';
  ELSE
    ALTER USER "${POSTGRES_APP_USER}" WITH PASSWORD '${PGPASSWORD_APP_SQL_ESCAPED}';
  END IF;
END \$\$;
GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${POSTGRES_APP_USER}";
-- PostgreSQL 15+ removed default CREATE on public schema; Airflow migrations need it.
GRANT ALL ON SCHEMA public TO "${POSTGRES_APP_USER}";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS vector;
ENDSQL

kubectl cp "$TMP_INIT_SQL" "$NAMESPACE/$POSTGRES_POD:/tmp/init.sql"
kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- \
  sh -ec "PGPASSWORD='$PGPASSWORD_SUPERUSER' psql -v ON_ERROR_STOP=1 -U postgres -d '$POSTGRES_DB' -f /tmp/init.sql && rm /tmp/init.sql"

# Delete the pgbouncer Deployment before apply to clear any stale pods that may
# be stuck in ImagePullBackOff from a previous image tag and blocking rolling updates.
kubectl delete deployment pgbouncer -n "$NAMESPACE" --ignore-not-found=true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: pgbouncer-users
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  userlist.txt: |
    "${POSTGRES_APP_USER}" "${PGPASSWORD_APP}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbouncer-config
  namespace: ${NAMESPACE}
data:
  pgbouncer.ini: |
    [databases]
    * = host=postgresql.${NAMESPACE}.svc.cluster.local port=5432

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 5432
    auth_type = scram-sha-256
    auth_file = /etc/pgbouncer/userlist.txt
    pool_mode = ${PGBOUNCER_POOL_MODE}
    max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
    default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
    reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE}
    server_reset_query = DISCARD ALL
    ignore_startup_parameters = extra_float_digits
    admin_users = ${POSTGRES_APP_USER}
    stats_users = ${POSTGRES_APP_USER}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pgbouncer
  template:
    metadata:
      labels:
        app: pgbouncer
    spec:
      containers:
        - name: pgbouncer
          image: edoburu/pgbouncer:v1.23.1-p3
          imagePullPolicy: IfNotPresent
          command: ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
          ports:
            - containerPort: 5432
              name: pgbouncer
          readinessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: pgbouncer-config
              mountPath: /etc/pgbouncer/pgbouncer.ini
              subPath: pgbouncer.ini
            - name: pgbouncer-users
              mountPath: /etc/pgbouncer/userlist.txt
              subPath: userlist.txt
      volumes:
        - name: pgbouncer-config
          configMap:
            name: pgbouncer-config
        - name: pgbouncer-users
          secret:
            secretName: pgbouncer-users
---
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: pgbouncer
  ports:
    - port: 5432
      targetPort: 5432
      name: pgbouncer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-backups
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${POSTGRES_BACKUP_PVC_SIZE}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: ${NAMESPACE}
spec:
  schedule: "${POSTGRES_BACKUP_SCHEDULE}"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: ${POSTGRES_BACKUP_HISTORY_LIMIT}
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: postgres-backup
              image: ${POSTGRES_IMAGE_REPOSITORY}:${POSTGRES_IMAGE_TAG}
              imagePullPolicy: IfNotPresent
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: postgres-creds
                      key: postgres-password
                - name: POSTGRES_DB
                  value: ${POSTGRES_DB}
                - name: POSTGRES_APP_USER
                  value: ${POSTGRES_APP_USER}
                - name: RETENTION_DAYS
                  value: "${POSTGRES_BACKUP_RETENTION_DAYS}"
              command:
                - /bin/bash
                - -ec
                - |
                  set -euo pipefail
                  timestamp="\$(date +%Y%m%d-%H%M%S)"
                  backup_dir="/backups/\${POSTGRES_DB}"
                  mkdir -p "\$backup_dir"
                  pg_dump -h postgresql.${NAMESPACE}.svc.cluster.local -U postgres -d "\$POSTGRES_DB" -Fc \
                    > "\$backup_dir/\${POSTGRES_DB}-\${timestamp}.dump"
                  pg_dumpall -h postgresql.${NAMESPACE}.svc.cluster.local -U postgres --globals-only \
                    > "\$backup_dir/globals-\${timestamp}.sql"
                  find "\$backup_dir" -type f -mtime +"\$RETENTION_DAYS" -delete
              volumeMounts:
                - name: postgres-backups
                  mountPath: /backups
          volumes:
            - name: postgres-backups
              persistentVolumeClaim:
                claimName: postgres-backups
EOF

if ! kubectl rollout status deployment/pgbouncer -n "$NAMESPACE" --timeout=5m; then
  echo ""
  echo "ERROR: PgBouncer deployment did not become ready within 5m. Diagnostics:"
  echo ""
  echo "--- Pod status ---"
  kubectl get pods -n "$NAMESPACE" -l app=pgbouncer -o wide || true
  echo ""
  echo "--- Pod events ---"
  PGBOUNCER_POD_DIAG="$(kubectl get pod -n "$NAMESPACE" -l app=pgbouncer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$PGBOUNCER_POD_DIAG" ]]; then
    kubectl describe pod "$PGBOUNCER_POD_DIAG" -n "$NAMESPACE" || true
    echo ""
    echo "--- Container logs ---"
    kubectl logs "$PGBOUNCER_POD_DIAG" -n "$NAMESPACE" --tail=80 || true
    echo ""
    echo "--- Previous container logs ---"
    kubectl logs "$PGBOUNCER_POD_DIAG" -n "$NAMESPACE" --previous --tail=80 || true
  else
    echo "  (no PgBouncer pod found)"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20 || true
  fi
  exit 1
fi

# 5. Metadata
if [[ -d "./charts/unity-catalog" ]]; then
  helm upgrade --install unity-catalog ./charts/unity-catalog \
    --namespace "$NAMESPACE"
else
  echo "WARN: ./charts/unity-catalog not found; skipping Unity Catalog Helm release."
fi

# 6. Compute
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace "$NAMESPACE" \
  -f config/values/spark-values.yaml
helm upgrade --install trino trino/trino \
  --namespace "$NAMESPACE" \
  -f "$TRINO_VALUES_RENDERED"

# 7. Orchestration
# Uninstall any previous Airflow release FIRST — a prior install may have adopted the
# airflow-metadata secret into Helm's release manifest; if so, helm uninstall would
# delete it. Creating the secret AFTER uninstall guarantees it is fresh and unowned.
helm uninstall airflow -n "$NAMESPACE" 2>/dev/null || true

# Create the airflow-metadata secret with the full SQLAlchemy DSN.
# airflow-values.yaml sets data.metadataSecretName=airflow-metadata so the chart
# references this secret (key: connection) instead of constructing its own URL, which
# defaults to airflow-postgresql.data-stack when postgresql.enabled=false.
# Airflow connects directly to PostgreSQL (bypassing PgBouncer) to avoid SCRAM
# auth handshake issues with Airflow's internal connection pooler.
ENCODED_POSTGRES_USER="$(jq -nr --arg value "$POSTGRES_APP_USER" '$value|@uri')"
ENCODED_POSTGRES_PASSWORD="$(jq -nr --arg value "$PGPASSWORD_APP" '$value|@uri')"
AIRFLOW_DB_DSN="postgresql+psycopg2://${ENCODED_POSTGRES_USER}:${ENCODED_POSTGRES_PASSWORD}@postgresql.${NAMESPACE}.svc.cluster.local:5432/${POSTGRES_DB}"
kubectl create secret generic airflow-metadata \
  --namespace "$NAMESPACE" \
  --from-literal="connection=${AIRFLOW_DB_DSN}" \
  --dry-run=client -o yaml | kubectl apply -f -

AIRFLOW_INSTALL_FAILED=false
if ! helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  -f config/values/airflow-values.yaml \
  --timeout 10m; then
  AIRFLOW_INSTALL_FAILED=true
  echo ""
  echo "[WARN] Airflow install timed out — skipping. Diagnostics:"
  echo ""
  echo "--- Pod status ---"
  kubectl get pods -n "$NAMESPACE" -l release=airflow -o wide || true
  echo ""
  echo "--- Pod events (airflow-related) ---"
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | grep -i 'airflow\|Back\|Error\|Failed\|OOM\|Kill' | tail -30 || true
  echo ""
  echo "--- Migration job logs ---"
  MIGRATION_POD="$(kubectl get pods -n "$NAMESPACE" -l 'job-name=airflow-run-airflow-migrations' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$MIGRATION_POD" ]]; then
    echo "  [current]"
    kubectl logs "$MIGRATION_POD" -n "$NAMESPACE" --all-containers --tail=60 2>/dev/null || true
    echo "  [previous crash]"
    kubectl logs "$MIGRATION_POD" -n "$NAMESPACE" --all-containers --previous --tail=60 2>/dev/null || echo "  (no previous log)"
  else
    echo "  (migration pod not found)"
  fi
  echo ""
  echo "--- airflow-metadata secret check ---"
  kubectl get secret airflow-metadata -n "$NAMESPACE" -o jsonpath='{.data.connection}' 2>/dev/null \
    | base64 -d | sed 's/:\/\/[^:]*:[^@]*@/:\/\/<user>:<pass>@/' || echo "  (secret not found — this is likely the root cause)"
  echo ""
  echo "[WARN] Remaining steps will continue. Re-run deploy-node.sh once Airflow is fixed."
  echo "       Dependencies on Airflow (not yet functional):"
  echo "         - Data pipeline DAGs (any workflow orchestration)"
  echo "         - Scheduled ETL jobs managed via Airflow"
  echo "         - Pipeline-triggered MLflow runs (if DAGs feed MLflow)"
  echo "         - KServe batch inference jobs triggered by Airflow DAGs"
fi

# 8. ML & Workspace
if [[ -d "./charts/mlflow" ]]; then
  helm upgrade --install mlflow ./charts/mlflow \
    --namespace "$NAMESPACE"
else
  echo "WARN: ./charts/mlflow not found; skipping MLflow Helm release."
fi

if command -v k3s >/dev/null 2>&1; then
  K3S_IMAGE_LIST="$(k3s ctr images list 2>/dev/null || true)"
  if ! grep -q 'jupyter-health-env:latest' <<< "$K3S_IMAGE_LIST"; then
    echo "ERROR: Required local image 'jupyter-health-env:latest' is not present in k3s containerd."
    echo "Run sudo -E bash deploy/bootstrap.sh on this server, or import the image manually,"
    echo "before re-running deploy/deploy-node.sh for the JupyterHub step."
    exit 1
  fi
fi

helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace "$NAMESPACE" \
  -f config/values/jupyterhub-values.yaml \
  --set-string ingress.hosts[0]="${JUPYTER_HOST}"

# 9. Serving
# Download and apply KServe manifest (pinned version v0.11.0)
KSERVE_MANIFEST="deploy/kserve-v0.11.0.yaml"
if [ ! -f "$KSERVE_MANIFEST" ]; then
  curl -fsSL https://github.com/kserve/kserve/releases/download/v0.11.0/kserve.yaml -o "$KSERVE_MANIFEST"
fi
kubectl apply -f "$KSERVE_MANIFEST"

if [[ "$AIRFLOW_INSTALL_FAILED" == "true" ]]; then
  echo ""
  echo "⚠️  Deployment complete with warnings:"
  echo "   - Airflow did not install successfully. Re-run deploy-node.sh to retry."
  echo "   - All other services (PostgreSQL, PgBouncer, MinIO, Trino, Spark,"
  echo "     MLflow, JupyterHub, KServe) are deployed and functional."
  echo "   - Airflow dependencies: DAG orchestration, scheduled ETL, pipeline-"
  echo "     triggered MLflow runs, and Airflow-scheduled KServe batch jobs."
else
  echo "✅ Deployment Complete! Node is ready."
fi
