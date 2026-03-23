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
echo "[1/8] Installing system dependencies..."
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
echo "[2/8] Installing yq..."
YQ_VERSION="v4.44.3"
wget -qO /usr/local/bin/yq \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
chmod +x /usr/local/bin/yq
echo "  -> $(yq --version)"

# ---- 3. Helm -----------------------------------------------
echo ""
echo "[3/8] Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "  -> $(helm version --short)"

# ---- 4. k3s ------------------------------------------------
echo ""
echo "[4/8] Installing k3s (includes kubectl + local-path StorageClass)..."
# --disable=traefik: project uses ingress-nginx, not Traefik
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik" sh -

# k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "  Waiting for control-plane node to become Ready (timeout: 120s)..."
kubectl wait node --all --for=condition=Ready --timeout=120s
echo "  -> Cluster ready"
kubectl get nodes -o wide

# ---- 5. kubeconfig for calling user ------------------------
echo ""
echo "[5/8] Configuring kubeconfig for $REAL_USER..."
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
echo "[6/8] Registering Helm repositories..."

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
echo "[7/10] Installing Node.js 20 and portless..."
# NodeSource LTS repo for Ubuntu
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y -q nodejs
echo "  -> $(node --version)  npm $(npm --version)"

# Install portless globally — must NOT be a project dependency
npm install -g portless
echo "  -> portless $(portless --version 2>/dev/null || echo 'installed')"

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
echo "[8/10] Building custom Jupyter health environment image..."
JUPYTER_BUILD_CTX="$PROJECT_ROOT/docker/jupyter-health-env"
IMAGE_TAG="jupyter-health-env:latest"

docker build -t "$IMAGE_TAG" "$JUPYTER_BUILD_CTX"
echo "  -> Image built: $IMAGE_TAG"

# Import into k3s containerd so pods can pull with imagePullPolicy: Never
echo "  -> Importing image into k3s containerd runtime..."
docker save "$IMAGE_TAG" | k3s ctr images import -
echo "  -> Image available in k3s: $IMAGE_TAG"

# ---- 9. Namespace + secrets --------------------------------
echo ""
echo "[9/10] Provisioning Kubernetes namespace and secrets..."
bash "$SCRIPT_DIR/setup-secrets.sh"

# ---- 10. Portless proxy initial start ---------------------
echo ""
echo "[10/10] Starting portless proxy (port 1355)..."
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
echo ""
echo "In-cluster ingress hostnames (add to /etc/hosts -> $(hostname -I | awk '{print $1}')):"
echo "  jupyter.health-node.local   — JupyterHub notebook workspace"
echo "  grafana.health-node.local   — Grafana dashboards"
echo ""
echo "NOTE: Run 'newgrp docker' or re-login for Docker group membership to apply."
