#!/bin/bash
# ============================================================
# Public Health AI Node — Local Dev Proxy
# Uses portless (https://port1355.dev/) to expose every k8s
# service at a named .localhost:1355 URL instead of raw ports.
#
# Usage:
#   bash deploy/dev-proxy.sh          # start all proxies
#   bash deploy/dev-proxy.sh stop     # kill all proxies
#   bash deploy/dev-proxy.sh status   # show running proxies
# ============================================================
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

# ---- Dependency checks -------------------------------------
for cmd in kubectl portless; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Run deploy/bootstrap.sh first."
    exit 1
  fi
done

# Verify cluster connectivity before spawning proxies
if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
  echo "ERROR: Cannot reach Kubernetes cluster. Check KUBECONFIG=$KUBECONFIG"
  exit 1
fi

# ---- PID file for lifecycle management ---------------------
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/health-node-dev-proxy.pids"

stop_all() {
  if [[ -f "$PID_FILE" ]]; then
    echo "Stopping all health-node dev proxies..."
    while IFS= read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && echo "  -> killed PID $pid"
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
    echo "All proxies stopped."
  else
    echo "No running proxies found (no PID file at $PID_FILE)."
  fi
  exit 0
}

status_all() {
  echo "portless proxy status:"
  portless proxy status 2>/dev/null || echo "  (portless proxy not running)"
  echo ""
  if [[ -f "$PID_FILE" ]]; then
    echo "Port-forward processes:"
    while IFS= read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        echo "  PID $pid  [running]  $(ps -p "$pid" -o args= 2>/dev/null || true)"
      else
        echo "  PID $pid  [dead]"
      fi
    done < "$PID_FILE"
  else
    echo "No PID file — dev-proxy not started."
  fi
  exit 0
}

[[ "${1:-}" == "stop" ]]   && stop_all
[[ "${1:-}" == "status" ]] && status_all

# ---- Ensure portless proxy daemon is running ---------------
echo "Starting portless proxy daemon..."
portless proxy start 2>/dev/null || true

# ---- Service definitions -----------------------------------
# Format: "portless-name  namespace  svc/service-name  remote-port"
# portless injects $PORT as the local listening port;
# kubectl receives it via: sh -c 'kubectl port-forward ... $PORT:remote'
declare -a SERVICES=(
  "grafana.health-node     monitoring    svc/monitoring-grafana                80"
  "jupyter.health-node     data-stack    svc/proxy-public                      80"
  "minio.health-node       data-stack    svc/minio                             9001"
  "minio-api.health-node   data-stack    svc/minio                             9000"
  "airflow.health-node     data-stack    svc/airflow-webserver                 8080"
  "mlflow.health-node      data-stack    svc/mlflow                            5000"
  "trino.health-node       data-stack    svc/trino                             8080"
  "prometheus.health-node  monitoring    svc/monitoring-kube-prometheus-stack  9090"
)

# ---- Start port-forward + portless pairs -------------------
if [[ -f "$PID_FILE" ]]; then
  echo "ERROR: PID file $PID_FILE already exists. Is the dev proxy already running?"
  echo "       Run 'bash deploy/dev-proxy.sh stop' before starting a new instance."
  exit 1
fi
touch "$PID_FILE"

echo ""
echo "Starting port-forwards and portless routes..."
echo ""

for entry in "${SERVICES[@]}"; do
  read -r NAME NAMESPACE SERVICE REMOTE_PORT <<< "$entry"

  # Verify the service exists before trying to port-forward
  if ! kubectl get "$SERVICE" -n "$NAMESPACE" &>/dev/null; then
    echo "  [SKIP] $NAME — $SERVICE not found in namespace $NAMESPACE (deploy first?)"
    continue
  fi

  # portless wraps the sh subprocess; $PORT is expanded inside sh, not here
  # shellcheck disable=SC2016
  portless "$NAME" sh -c \
    "kubectl port-forward $SERVICE \$PORT:$REMOTE_PORT -n $NAMESPACE --kubeconfig=\"$KUBECONFIG\"" \
    &>/dev/null &

  PROXY_PID=$!
  echo "$PROXY_PID" >> "$PID_FILE"
  echo "  http://${NAME}.localhost:1355  -->  ${NAMESPACE}/${SERVICE}:${REMOTE_PORT}  (PID $PROXY_PID)"
done

echo ""
echo "=================================================="
echo "  Dev proxy started. All services at port 1355."
echo "=================================================="
echo ""
echo "Tip: 'bash deploy/dev-proxy.sh stop'   — stop all"
echo "     'bash deploy/dev-proxy.sh status' — show status"
echo ""
echo "PIDs saved to: $PID_FILE"
