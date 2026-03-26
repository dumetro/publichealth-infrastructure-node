variable "kubeconfig_path" {
  description = "Path to kubeconfig used for Kubernetes and Helm providers."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Primary namespace for the data platform."
  type        = string
  default     = "data-stack"
}

variable "domain" {
  description = "Base domain for ingress hosts."
  type        = string
  default     = "health-node.local"
}

variable "minio_root_user" {
  description = "MinIO root username."
  type        = string
  default     = "admin"
}

variable "minio_root_password" {
  description = "MinIO root password."
  type        = string
  sensitive   = true
}

variable "unity_catalog_admin_token" {
  description = "Unity Catalog admin access token."
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  sensitive   = true
}

variable "minio_buckets" {
  description = "Buckets to create in MinIO."
  type        = list(string)
  default     = ["raw-data", "iceberg-tables", "mlflow-artifacts"]
}

variable "deploy_optional_local_charts" {
  description = "Set true to deploy local charts from ./charts when present."
  type        = bool
  default     = false
}
