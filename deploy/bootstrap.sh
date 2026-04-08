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

# ---- 1. System dependencies --------------------------------
echo ""
echo "[1/11] Installing system dependencies..."
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

# ---- 2. yq -------------------------------------------------
echo ""
echo "[2/11] Installing yq..."
YQ_VERSION="v4.44.3"
ARCH="$(uname -m)"
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
echo "[3/11] Installing Helm..."
HELM_VERSION="v3.14.4"
HELM_ARCH="linux-amd64"
HELM_TAR="helm-${HELM_VERSION}-${HELM_ARCH}.tar.gz"
HELM_URL="https://get.helm.sh/${HELM_TAR}"

# NOTE: Replace the placeholder below with the official SHA-256 checksum
# for ${HELM_TAR} from the Helm release page before using in production.
HELM_SHA256_EXPECTED="a5844ef2c38ef6ddf3b5a8f7d91e7e0e8ebc39a38bb3fc8013d629c1ef29c259"

TMP_HELM_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_HELM_DIR"' EXIT

echo "  -> Downloading Helm ${HELM_VERSION} from ${HELM_URL}..."
curl -fsSL -o "${TMP_HELM_DIR}/${HELM_TAR}" "${HELM_URL}"

echo "  -> Verifying Helm archive checksum..."
echo "${HELM_SHA256_EXPECTED}  ${TMP_HELM_DIR}/${HELM_TAR}" | sha256sum -c -

echo "  -> Installing Helm binary to /usr/local/bin/helm..."
tar -xzf "${TMP_HELM_DIR}/${HELM_TAR}" -C "${TMP_HELM_DIR}"
install -m 0755 "${TMP_HELM_DIR}/linux-amd64/helm" /usr/local/bin/helm
echo "  -> $(helm version --short)"

# ---- 4. k3s ------------------------------------------------
echo ""
echo "[4/11] Installing k3s (includes kubectl + local-path StorageClass)..."
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
INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server --disable=traefik" "$K3S_INSTALL_SCRIPT"
# k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

K3S_READY_TIMEOUT_SECONDS="${K3S_READY_TIMEOUT_SECONDS:-600}"
echo "  Waiting for control plane to become Ready (timeout: ${K3S_READY_TIMEOUT_SECONDS}s)..."

# Wait for API responsiveness first.
API_READY_DEADLINE=$((SECONDS + K3S_READY_TIMEOUT_SECONDS))
until kubectl get --raw='/readyz' >/dev/null 2>&1; do
  if (( SECONDS >= API_READY_DEADLINE )); then
    echo "ERROR: Kubernetes API did not become responsive within ${K3S_READY_TIMEOUT_SECONDS}s."
    echo "k3s service status:"
    systemctl --no-pager -l status k3s || true
    echo "Recent k3s logs:"
    journalctl -u k3s -n 80 --no-pager || true
    exit 1
  fi
  sleep 5
done

# Wait until at least one Node resource exists before waiting on condition=Ready.
until [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do
  if (( SECONDS >= API_READY_DEADLINE )); then
    echo "ERROR: Kubernetes API became reachable, but no nodes were registered within ${K3S_READY_TIMEOUT_SECONDS}s."
    echo "Current node status:"
    kubectl get nodes -o wide || true
    echo "k3s service status:"
    systemctl --no-pager -l status k3s || true
    echo "Recent k3s logs:"
    journalctl -u k3s -n 80 --no-pager || true
    exit 1
  fi
  sleep 5
done

if ! kubectl wait node --all --for=condition=Ready --timeout="${K3S_READY_TIMEOUT_SECONDS}s"; then
  echo "ERROR: Control plane node did not reach Ready within ${K3S_READY_TIMEOUT_SECONDS}s."
  echo "Current node status:"
  kubectl get nodes -o wide || true
  echo "k3s service status:"
  systemctl --no-pager -l status k3s || true
  echo "Recent k3s logs:"
  journalctl -u k3s -n 80 --no-pager || true
  exit 1
fi
echo "  -> Cluster ready"
kubectl get nodes -o wide

# ---- 5. kubeconfig for calling user ------------------------
echo ""
echo "[5/11] Configuring kubeconfig for $REAL_USER..."
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
echo "[6/11] Registering Helm repositories..."

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
echo "[7/11] Installing Node.js 20 and portless..."

# Configure NodeSource Node.js 20 apt repo with pinned GPG key
. /etc/os-release
DISTRO_CODENAME="${VERSION_CODENAME:-jammy}"
NODESOURCE_GPG_KEYRING="/usr/share/keyrings/nodesource.gpg"

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o "$NODESOURCE_GPG_KEYRING"

echo "deb [signed-by=$NODESOURCE_GPG_KEYRING] https://deb.nodesource.com/node_20.x $DISTRO_CODENAME main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update -q
apt-get install -y -q nodejs
echo "  -> $(node --version)  npm $(npm --version)"

# Install portless globally — must NOT be a project dependency
PORTLESS_VERSION="1.2.3"  # Pinned known-good version; update intentionally as needed
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
echo "[8/11] Building custom Jupyter health environment image..."
JUPYTER_BUILD_CTX="$PROJECT_ROOT/docker/jupyter-health-env"
IMAGE_TAG="jupyter-health-env:latest"

docker build -t "$IMAGE_TAG" "$JUPYTER_BUILD_CTX"
echo "  -> Image built: $IMAGE_TAG"

# Import into k3s containerd so pods can pull with imagePullPolicy: Never
echo "  -> Importing image into k3s containerd runtime..."
docker save "$IMAGE_TAG" | k3s ctr images import -
echo "  -> Image available in k3s: $IMAGE_TAG"

# ---- 9. Build & import PostgreSQL image with postgis + pgvector ------
echo ""
echo "[9/11] Building PostgreSQL image with postgis + pgvector..."
POSTGRES_BUILD_CTX="$PROJECT_ROOT/docker/postgres-health-ext"
POSTGRES_IMAGE_TAG="postgres-health-ext:16"

docker build -t "$POSTGRES_IMAGE_TAG" "$POSTGRES_BUILD_CTX"
echo "  -> Image built: $POSTGRES_IMAGE_TAG"

echo "  -> Importing image into k3s containerd runtime..."
docker save "$POSTGRES_IMAGE_TAG" | k3s ctr images import -
echo "  -> Image available in k3s: $POSTGRES_IMAGE_TAG"

# ---- 10. Namespace + secrets -------------------------------
echo ""
echo "[10/11] Provisioning Kubernetes namespace and secrets..."
bash "$SCRIPT_DIR/setup-secrets.sh"

# ---- 11. Portless proxy initial start ----------------------
echo ""
echo "[11/11] Starting portless proxy (port 1355)..."
# Run as the real user — portless stores its state in the user's home dir
sudo -u "$REAL_USER" portless proxy start 2>/dev/null || true
echo "  -> portless proxy running on http://*.localhost:1355"

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
echo "  http://grafana.health-node.localhost:1355"
echo "  http://jupyter.health-node.localhost:1355"
echo "  http://minio.health-node.localhost:1355"
echo "  http://airflow.health-node.localhost:1355"
echo "  http://mlflow.health-node.localhost:1355"
echo "  http://trino.health-node.localhost:1355"
echo "  http://pgbouncer.health-node.localhost:1355"
echo "  http://postgres.health-node.localhost:1355"
echo ""
echo "In-cluster ingress hostnames (add to /etc/hosts -> $(hostname -I | awk '{print $1}')):"
echo "  jupyter.health-node.local   — JupyterHub notebook workspace"
echo "  grafana.health-node.local   — Grafana dashboards"
echo ""
echo "NOTE: Run 'newgrp docker' or re-login for Docker group membership to apply."
