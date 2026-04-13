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

POSTGRES_APP_MD5="md5$(printf "%s%s" "$POSTGRES_APP_PASSWORD" "$POSTGRES_APP_USER" | md5sum | awk '{print $1}')"

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
  '.auth.rootPassword = strenv("MINIO_ROOT_PASSWORD")' \
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
helm upgrade --install minio bitnami/minio \
  --namespace "$NAMESPACE" --create-namespace \
  --set-string auth.rootUser="$MINIO_ROOT_USER" \
  -f "$MINIO_SECRET_VALUES"
# NOTE: Buckets are not created automatically at deploy time.
# Create them manually after deploy: mc mb local/raw local/standard local/published

# 4. Database
helm upgrade --install postgresql bitnami/postgresql \
  --namespace "$NAMESPACE" \
  -f config/values/postgres-values.yaml \
  -f "$POSTGRES_SECRET_VALUES" \
  --set global.security.allowInsecureImages=true \
  --set-string image.repository="$POSTGRES_IMAGE_REPOSITORY" \
  --set-string image.tag="$POSTGRES_IMAGE_TAG" \
  --set-string auth.username="$POSTGRES_APP_USER" \
  --set-string auth.database="$POSTGRES_DB" \
  --set-string primary.persistence.storageClass="$STORAGE_CLASS" \
  --set-string primary.persistence.size="$POSTGRES_PERSISTENCE_SIZE"

kubectl rollout status statefulset/postgresql -n "$NAMESPACE" --timeout=5m

POSTGRES_POD="$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/component=primary,app.kubernetes.io/instance=postgresql -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$POSTGRES_POD" ]]; then
  echo "ERROR: Unable to find PostgreSQL primary pod to enable extensions"
  exit 1
fi

kubectl exec -n "$NAMESPACE" "$POSTGRES_POD" -- sh -ec "PGPASSWORD='$POSTGRES_SUPERUSER_PASSWORD' psql -v ON_ERROR_STOP=1 -U postgres -d '$POSTGRES_DB' -c \"CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS vector;\""

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: pgbouncer-users
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  userlist.txt: |
    "${POSTGRES_APP_USER}" "${POSTGRES_APP_MD5}"
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
    auth_type = md5
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
          image: edoburu/pgbouncer:1.23.1
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
                  timestamp="$(date +%Y%m%d-%H%M%S)"
                  backup_dir="/backups/${POSTGRES_DB}"
                  mkdir -p "$backup_dir"
                  pg_dump -h postgresql.${NAMESPACE}.svc.cluster.local -U postgres -d "$POSTGRES_DB" -Fc \
                    > "$backup_dir/${POSTGRES_DB}-${timestamp}.dump"
                  pg_dumpall -h postgresql.${NAMESPACE}.svc.cluster.local -U postgres --globals-only \
                    > "$backup_dir/globals-${timestamp}.sql"
                  find "$backup_dir" -type f -mtime +"$RETENTION_DAYS" -delete
              volumeMounts:
                - name: postgres-backups
                  mountPath: /backups
          volumes:
            - name: postgres-backups
              persistentVolumeClaim:
                claimName: postgres-backups
EOF

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
helm upgrade --install airflow apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  -f config/values/airflow-values.yaml

# 8. ML & Workspace
if [[ -d "./charts/mlflow" ]]; then
  helm upgrade --install mlflow ./charts/mlflow \
    --namespace "$NAMESPACE"
else
  echo "WARN: ./charts/mlflow not found; skipping MLflow Helm release."
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

echo "✅ Deployment Complete! Node is ready."
