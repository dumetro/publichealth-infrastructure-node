#!/bin/bash
set -euo pipefail
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
  if curl -sf --max-time 3 "http://grafana.health-node.localhost:1355" -o /dev/null; then
    echo "  -> grafana.health-node.localhost:1355: reachable"
  else
    echo "  [WARN] grafana route not reachable — run: bash deploy/dev-proxy.sh"
  fi
fi

echo ""
echo "✅ Node is healthy and integrated."
