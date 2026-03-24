# publichealth-infrastructure-node
Public Health Infrastructure Node for AI workloads

## Dev Proxy (portless)

This project uses [portless](https://port1355.dev/) to expose Kubernetes services as named
`.localhost:1355` URLs instead of raw port numbers during local development.

### Quick start

```bash
# 1. Bootstrap the node (installs k3s, Helm, Node.js, portless, etc.)
sudo bash deploy/bootstrap.sh

# 2. Deploy all services
bash deploy/deploy-node.sh

# 3. Start the dev proxy
bash deploy/dev-proxy.sh
```

After step 3, services are available at named URLs:

| Service    | URL                                        |
|------------|--------------------------------------------|
| Grafana    | http://grafana.health-node.localhost:1355  |
| JupyterHub | http://jupyter.health-node.localhost:1355  |
| MinIO UI   | http://minio.health-node.localhost:1355    |
| Airflow    | http://airflow.health-node.localhost:1355  |
| MLflow     | http://mlflow.health-node.localhost:1355   |
| Trino      | http://trino.health-node.localhost:1355    |

Stop the proxy with `bash deploy/dev-proxy.sh stop`.
