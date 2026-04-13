#!/bin/bash
# ============================================================
# Public Health AI Node — Bootstrap (Ubuntu 22+)
# Run ONCE before deploy/deploy-node.sh.
# Usage: sudo bash deploy/bootstrap.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Privilege check ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root or with sudo."
  echo "Usage: sudo bash deploy/bootstrap.sh"
  exit 1
fi

# Determine the calling (non-root) user for home-dir setup
REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- OS check ---
if ! grep -qi "ubuntu" /etc/os-release; then
  echo "ERROR: This script is designed for Ubuntu 22.04+."
  exit 1
fi
UBUNTU_MAJOR=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
if [[ "$UBUNTU_MAJOR" -lt 22 ]]; then
  echo "ERROR: Ubuntu 22 or later required (found Ubuntu $UBUNTU_MAJOR)."
  exit 1
fi

echo "=================================================="
echo "  Public Health AI Node — Bootstrap"
echo "  Ubuntu $UBUNTU_MAJOR detected | User: $REAL_USER"
echo "=================================================="

# Detect architecture once — used by yq, Helm, and docker buildx install steps.
ARCH="$(uname -m)"

# ---- 1. System dependencies --------------------------------
echo ""
echo "[1/12] Installing system dependencies..."
# Remove any stale NodeSource apt source written by a previous bootstrap run.
# If left in place, apt-get update fails here before step 7 can overwrite it.
rm -f /etc/apt/sources.list.d/nodesource.list
apt-get update -q
apt-get install -y -q \
  curl wget ca-certificates gnupg lsb-release \
  apt-transport-https software-properties-common \
  docker.io git jq

systemctl enable --now docker
if [[ "$REAL_USER" != "root" ]]; then
  usermod -aG docker "$REAL_USER"
  echo "  -> Added $REAL_USER to the 'docker' group (re-login required to take effect)"
fi

# Ensure docker buildx plugin is present — required for BuildKit builds.
if ! docker buildx version >/dev/null 2>&1; then
  echo "  -> docker buildx not found, installing..."
  BUILDX_VERSION="v0.17.1"
  case "$ARCH" in
    x86_64|amd64)  BUILDX_ARCH="amd64" ;;
    aarch64|arm64) BUILDX_ARCH="arm64" ;;
    *) echo "ERROR: Unsupported architecture for docker buildx: $ARCH"; exit 1 ;;
  esac
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-buildx
  chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
  echo "  -> $(docker buildx version)"
else
  echo "  -> docker buildx already installed: $(docker buildx version)"
fi

# ---- 2. yq -------------------------------------------------
echo ""
echo "[2/12] Installing yq..."
YQ_VERSION="v4.44.3"
case "$ARCH" in
  x86_64|amd64)
    YQ_ARCH="amd64"
    ;;
  aarch64|arm64)
    YQ_ARCH="arm64"
    ;;
  *)
    echo "ERROR: Unsupported architecture for yq: $ARCH"
    echo "       Supported architectures: amd64, arm64"
    exit 1
    ;;
esac
wget -qO /usr/local/bin/yq \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}"
chmod +x /usr/local/bin/yq
echo "  -> $(yq --version)"

# ---- 3. Helm -----------------------------------------------
echo ""
echo "[3/12] Installing Helm..."
HELM_VERSION="v3.14.4"
# $ARCH is already set by the yq step above (uname -m output).
case "$ARCH" in
  x86_64|amd64)
    HELM_ARCH="linux-amd64"
    HELM_SHA256_EXPECTED="a5844ef2c38ef6ddf3b5a8f7d91e7e0e8ebc39a38bb3fc8013d629c1ef29c259"
    ;;
  aarch64|arm64)
    HELM_ARCH="linux-arm64"
    HELM_SHA256_EXPECTED="113ccc6a5d44b47a41f3d1ebae8a7f40a38be4aee36619b44c77ead9c4b73c61"
    ;;
  *)
    echo "ERROR: Unsupported architecture for Helm: $ARCH"
    exit 1
    ;;
esac
HELM_TAR="helm-${HELM_VERSION}-${HELM_ARCH}.tar.gz"
HELM_URL="https://get.helm.sh/${HELM_TAR}"

TMP_HELM_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_HELM_DIR"' EXIT

echo "  -> Downloading Helm ${HELM_VERSION} (${HELM_ARCH}) from ${HELM_URL}..."
curl -fsSL -o "${TMP_HELM_DIR}/${HELM_TAR}" "${HELM_URL}"

echo "  -> Verifying Helm archive checksum..."
echo "${HELM_SHA256_EXPECTED}  ${TMP_HELM_DIR}/${HELM_TAR}" | sha256sum -c -

echo "  -> Installing Helm binary to /usr/local/bin/helm..."
tar -xzf "${TMP_HELM_DIR}/${HELM_TAR}" -C "${TMP_HELM_DIR}"
install -m 0755 "${TMP_HELM_DIR}/${HELM_ARCH}/helm" /usr/local/bin/helm
echo "  -> $(helm version --short)"

# ---- 4. k3s ------------------------------------------------
echo ""
echo "[4/12] Installing k3s (includes kubectl + local-path StorageClass)..."
# --disable=traefik: project uses ingress-nginx, not Traefik
# Pin k3s version for reproducible installs; override by setting K3S_VERSION in the environment.
K3S_VERSION="${K3S_VERSION:-v1.30.4+k3s1}"
K3S_INSTALL_SCRIPT="/tmp/install-k3s.sh"

curl -sfL https://get.k3s.io -o "$K3S_INSTALL_SCRIPT"
if [[ ! -s "$K3S_INSTALL_SCRIPT" ]]; then
  echo "ERROR: Failed to download k3s installer script or script is empty."
  exit 1
fi
chmod 700 "$K3S_INSTALL_SCRIPT"

# Pre-flight: stop any existing k3s instance so ports 10248/10250 are free before install.
# This handles re-runs and stale processes from previous failed bootstraps.
# Set K3S_RESET_STATE=true for destructive cleanup of prior cluster state (fresh single-node init).
K3S_RESET_STATE="${K3S_RESET_STATE:-false}"
echo "  -> Stopping and resetting any existing k3s service state before (re)install..."
systemctl stop k3s 2>/dev/null || true
systemctl kill --kill-who=all k3s 2>/dev/null || true
systemctl reset-failed k3s 2>/dev/null || true

# Use installer helper when present to clean up stale k3s/containerd networking state.
if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
  /usr/local/bin/k3s-killall.sh || true
fi
# Kill any surviving k3s processes that systemd did not reap
pkill -TERM -f '/usr/local/bin/k3s' 2>/dev/null || true
pkill -TERM -x kubelet 2>/dev/null || true
# Wait up to 30s for ports 10248 and 10250 to be released
_port_wait=0
until ! ss -tlnp 2>/dev/null | grep -qE ':10248|:10250'; do
  if (( _port_wait >= 30 )); then
    echo "WARNING: Ports 10248/10250 still in use after 30s — forcing SIGKILL"
    pkill -KILL -f '/usr/local/bin/k3s' 2>/dev/null || true
    pkill -KILL -x kubelet 2>/dev/null || true

    # Kill whichever process actually owns the listener sockets.
    LISTENER_PIDS="$(ss -tlnp 2>/dev/null | awk '/:10248|:10250/ {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
    if [[ -n "$LISTENER_PIDS" ]]; then
      for pid in $LISTENER_PIDS; do
        kill -9 "$pid" 2>/dev/null || true
      done
    fi
    sleep 2
    if ss -tlnp 2>/dev/null | grep -qE ':10248|:10250'; then
      echo "ERROR: Ports 10248/10250 are still occupied after forced cleanup."
      ss -tlnp 2>/dev/null | grep -E ':10248|:10250' || true
      echo "Refusing to continue because k3s will fail to start while kubelet ports are busy."
      exit 1
    fi
    break
  fi
  sleep 1
  (( _port_wait++ )) || true
done
unset _port_wait

if [[ "$K3S_RESET_STATE" == "true" ]]; then
  echo "  -> K3S_RESET_STATE=true: removing previous k3s datastore for a clean bootstrap"
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    /usr/local/bin/k3s-uninstall.sh || true
  fi
  rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/lib/kubelet /var/lib/cni /etc/cni/net.d
fi

INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server --disable=traefik" "$K3S_INSTALL_SCRIPT"
systemctl daemon-reload
systemctl reset-failed k3s 2>/dev/null || true
if ! systemctl restart k3s; then
  echo "ERROR: systemctl restart k3s failed immediately after install."
  systemctl --no-pager -l status k3s || true
  echo "Last 120 k3s logs:"
  journalctl -u k3s -n 120 --no-pager || true
  exit 1
fi
# k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

K3S_READY_TIMEOUT_SECONDS="${K3S_READY_TIMEOUT_SECONDS:-1200}"
K3S_NODE_REGISTRATION_TIMEOUT="${K3S_NODE_REGISTRATION_TIMEOUT:-1800}"
# Phase 1: Wait for API HTTP 200
echo "  Waiting for control plane ready (API: ${K3S_READY_TIMEOUT_SECONDS}s, node registration: ${K3S_NODE_REGISTRATION_TIMEOUT}s)..."
echo "  [Phase 1/3] Waiting for Kubernetes API HTTP 200..."
API_READY_DEADLINE=$((SECONDS + K3S_READY_TIMEOUT_SECONDS))
until kubectl get --raw='/readyz' 2>/dev/null | grep -q 'ok'; do
  if (( SECONDS >= API_READY_DEADLINE )); then
    echo "ERROR: Kubernetes API did not respond successfully within ${K3S_READY_TIMEOUT_SECONDS}s."
    echo "k3s service status:"
    systemctl --no-pager -l status k3s || true
    echo "RBAC/bootstrap readiness diagnostics (last 200 lines):"
    journalctl -u k3s -n 200 --no-pager | grep -E 'rbac/bootstrap-roles|readyz check failed|Kubelet failed to wait for apiserver ready|runtime core not ready|Failed to retrieve node info' || true
    echo "Last 100 k3s logs:"
    journalctl -u k3s -n 100 --no-pager || true
    if journalctl -u k3s -n 400 --no-pager | grep -q 'poststarthook/rbac/bootstrap-roles failed'; then
      echo "HINT: Detected persistent RBAC bootstrap hook failure."
      echo "      Re-run with a clean datastore: K3S_RESET_STATE=true sudo bash deploy/bootstrap.sh"
    fi
    exit 1
  fi
  sleep 5
done
echo "  -> API is responding"

# Phase 2: Wait for node registration (longer timeout, separate deadline)
echo "  [Phase 2/3] Waiting for node registration..."
NODE_REGISTRATION_DEADLINE=$((SECONDS + K3S_NODE_REGISTRATION_TIMEOUT))
until [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do
  if (( SECONDS >= NODE_REGISTRATION_DEADLINE )); then
    echo "ERROR: Node did not register within ${K3S_NODE_REGISTRATION_TIMEOUT}s."
    echo "Current node status:"
    kubectl get nodes -o wide 2>&1 || echo "  (kubectl get nodes failed)"
    echo "k3s service status:"
    systemctl --no-pager -l status k3s || true
    echo "Checking for 'runtime core not ready' errors in logs:"
    journalctl -u k3s --grep "runtime core not ready" -n 20 --no-pager || echo "  (no 'runtime core not ready' errors)"
    echo "Last 100 k3s logs:"
    journalctl -u k3s -n 100 --no-pager || true
    exit 1
  fi
  sleep 5
done
echo "  -> Node resource registered"

# Phase 3: Wait for node Ready condition
echo "  [Phase 3/3] Waiting for node Ready condition..."
if ! kubectl wait node --all --for=condition=Ready --timeout="${K3S_NODE_REGISTRATION_TIMEOUT}s"; then
  echo "ERROR: Node did not reach Ready within timeout."
  echo "Current node status and conditions:"
  kubectl describe nodes || true
  echo "k3s service status:"
  systemctl --no-pager -l status k3s || true
  echo "Last 100 k3s logs:"
  journalctl -u k3s -n 100 --no-pager || true
  exit 1
fi
echo "  -> Node Ready"
kubectl get nodes -o wide

# ---- 5. kubeconfig for calling user ------------------------
echo ""
echo "[5/12] Configuring kubeconfig for $REAL_USER..."
KUBE_DIR="$REAL_HOME/.kube"
mkdir -p "$KUBE_DIR"
cp /etc/rancher/k3s/k3s.yaml "$KUBE_DIR/config"
chmod 600 "$KUBE_DIR/config"
chown -R "$REAL_USER:$REAL_USER" "$KUBE_DIR"

BASHRC="$REAL_HOME/.bashrc"
if ! grep -q "KUBECONFIG" "$BASHRC" 2>/dev/null; then
  echo 'export KUBECONFIG=~/.kube/config' >> "$BASHRC"
  echo "  -> KUBECONFIG persisted to $BASHRC"
fi
echo "  -> kubeconfig written to $KUBE_DIR/config"

# ---- 6. Helm repositories ----------------------------------
echo ""
echo "[6/12] Registering Helm repositories..."

# Chart source mapping used by deploy/deploy-node.sh:
# - MinIO + PostgreSQL use Bitnami charts (repo key: bitnami)
# - Grafana is deployed as a subchart of kube-prometheus-stack (repo key: prometheus-community)
# - MLflow uses a local chart path (./charts/mlflow), so no remote repo entry is required

declare -A HELM_REPOS=(
  [ingress-nginx]="https://kubernetes.github.io/ingress-nginx"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [bitnami]="https://charts.bitnami.com/bitnami"
  [spark-operator]="https://kubeflow.github.io/spark-operator"
  [trino]="https://trinodb.github.io/charts"
  [apache-airflow]="https://airflow.apache.org"
  [jupyterhub]="https://jupyterhub.github.io/helm-chart/"
)

for REPO_NAME in "${!HELM_REPOS[@]}"; do
  URL="${HELM_REPOS[$REPO_NAME]}"
  if helm repo list 2>/dev/null | grep -q "^${REPO_NAME}"; then
    echo "  -> $REPO_NAME already registered, skipping"
  else
    helm repo add "$REPO_NAME" "$URL"
    echo "  -> Added: $REPO_NAME"
  fi
done

helm repo update
echo "  -> All repos up to date"
helm repo list

# ---- 7. Node.js 20 + portless ---------------------------------
echo ""
echo "[7/12] Installing Node.js 20 and portless..."

# Configure NodeSource Node.js 20 apt repo with pinned GPG key.
# NodeSource unified their repo under the 'nodistro' suite — per-distro codename
# paths (e.g. jammy, noble) are no longer published and return 404.
NODESOURCE_GPG_KEYRING="/usr/share/keyrings/nodesource.gpg"
rm -f "$NODESOURCE_GPG_KEYRING"

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o "$NODESOURCE_GPG_KEYRING"

echo "deb [signed-by=$NODESOURCE_GPG_KEYRING] https://deb.nodesource.com/node_20.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update -q
apt-get install -y -q nodejs
echo "  -> $(node --version)  npm $(npm --version)"

# Install portless globally — must NOT be a project dependency
PORTLESS_VERSION="0.10.1"  # Pinned known-good version; update intentionally as needed
npm install -g "portless@${PORTLESS_VERSION}"
echo "  -> portless ${PORTLESS_VERSION} (binary: $(portless --version 2>/dev/null || echo 'installed'))"

# Persist portless proxy auto-start for the calling user's login shell.
# portless proxy start is idempotent; safe to call on subsequent logins.
BASHRC="$REAL_HOME/.bashrc"
if ! grep -q 'portless proxy start' "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" <<'EOF'

# portless — local dev reverse proxy (port 1355)
# Starts automatically; maps all k8s service port-forwards to named .localhost URLs.
if command -v portless &>/dev/null; then
  portless proxy start --quiet 2>/dev/null || true
fi
EOF
  echo "  -> portless proxy auto-start added to $BASHRC"
fi

# ---- 8. Build & import custom Jupyter image ----------------
echo ""
echo "[8/12] Building custom Jupyter health environment image..."
JUPYTER_BUILD_CTX="$PROJECT_ROOT/docker/jupyter-health-env"
IMAGE_TAG="jupyter-health-env:latest"

DOCKER_BUILDKIT=1 docker build -t "$IMAGE_TAG" "$JUPYTER_BUILD_CTX"
echo "  -> Image built: $IMAGE_TAG"

# Import into k3s containerd so pods can pull with imagePullPolicy: Never
echo "  -> Importing image into k3s containerd runtime..."
docker save "$IMAGE_TAG" | k3s ctr images import -
echo "  -> Image available in k3s: $IMAGE_TAG"

# ---- 9. Build & import PostgreSQL image with postgis + pgvector ------
echo ""
echo "[9/12] Building PostgreSQL image with postgis + pgvector..."
POSTGRES_BUILD_CTX="$PROJECT_ROOT/docker/postgres-health-ext"
POSTGRES_IMAGE_TAG="postgres-health-ext:16"

DOCKER_BUILDKIT=1 docker build -t "$POSTGRES_IMAGE_TAG" "$POSTGRES_BUILD_CTX"
echo "  -> Image built: $POSTGRES_IMAGE_TAG"

echo "  -> Importing image into k3s containerd runtime..."
docker save "$POSTGRES_IMAGE_TAG" | k3s ctr images import -
echo "  -> Image available in k3s: $POSTGRES_IMAGE_TAG"

# ---- 10. Namespace + secrets -------------------------------
echo ""
echo "[10/12] Provisioning Kubernetes namespace and secrets..."
(cd "$PROJECT_ROOT" && bash "$SCRIPT_DIR/setup-secrets.sh")

# ---- 11. Portless proxy initial start ----------------------
echo ""
echo "[11/12] Starting portless proxy (port 1355)..."
# Run as the real user — portless stores its state in the user's home dir
sudo -u "$REAL_USER" portless proxy start 2>/dev/null || true
echo "  -> portless proxy running on http://*.localhost:1355"

# ---- 12. /etc/hosts — in-cluster ingress hostnames ----------
echo ""
echo "[12/12] Updating /etc/hosts with in-cluster ingress hostnames..."
NODE_IP="$(hostname -I | awk '{print $1}')"
INGRESS_HOSTS=(
  "$(yq e '.jupyterhub.hostname'        "$PROJECT_ROOT/config/env-config.yaml")"
  "$(yq e '.monitoring.grafana.domain'  "$PROJECT_ROOT/config/env-config.yaml")"
)
for HOST in "${INGRESS_HOSTS[@]}"; do
  if grep -qF "$HOST" /etc/hosts; then
    EXISTING_IP="$(awk "/$HOST/"'{print $1; exit}' /etc/hosts)"
    if [[ "$EXISTING_IP" == "$NODE_IP" ]]; then
      echo "  -> $HOST already mapped to $NODE_IP, skipping"
    else
      sed -i "/$HOST/d" /etc/hosts
      echo "$NODE_IP  $HOST" >> /etc/hosts
      echo "  -> Updated: $HOST  ($EXISTING_IP -> $NODE_IP)"
    fi
  else
    echo "$NODE_IP  $HOST" >> /etc/hosts
    echo "  -> Added: $NODE_IP  $HOST"
  fi
done
echo "  -> /etc/hosts ready"

# ---- Done --------------------------------------------------
echo ""
echo "=================================================="
echo "  Bootstrap complete!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1.  bash deploy/deploy-node.sh"
echo "  2.  bash deploy/dev-proxy.sh      # named local URLs for all k8s services"
echo ""
echo "portless service URLs (available after 'bash deploy/dev-proxy.sh'):"
echo "  http://grafana.dakar-datasphere-node.localhost:1355"
echo "  http://jupyter.dakar-datasphere-node.localhost:1355"
echo "  http://minio.dakar-datasphere-node.localhost:1355"
echo "  http://airflow.dakar-datasphere-node.localhost:1355"
echo "  http://mlflow.dakar-datasphere-node.localhost:1355"
echo "  http://trino.dakar-datasphere-node.localhost:1355"
echo "  http://pgbouncer.dakar-datasphere-node.localhost:1355"
echo "  http://postgres.dakar-datasphere-node.localhost:1355"
echo ""
echo "In-cluster ingress hostnames (written to /etc/hosts -> $NODE_IP):"
echo "  jupyter.dakar-datasphere-node.local   — JupyterHub notebook workspace"
echo "  grafana.dakar-datasphere-node.local   — Grafana dashboards"
echo ""
echo "NOTE: Run 'newgrp docker' or re-login for Docker group membership to apply."
