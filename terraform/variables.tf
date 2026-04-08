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

variable "airflow_fernet_key" {
  description = "Airflow Fernet key used to encrypt connection metadata."
  type        = string
  sensitive   = true
}

variable "airflow_webserver_secret_key" {
  description = "Airflow webserver secret key for session signing."
  type        = string
  sensitive   = true
}

variable "airflow_admin_password" {
  description = "Password for the default Airflow admin user."
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

variable "postgres_image_repository" {
  description = "Local PostgreSQL image repository with postgis and pgvector extensions."
  type        = string
  default     = "postgres-health-ext"
}

variable "postgres_image_tag" {
  description = "Tag for local PostgreSQL extension image."
  type        = string
  default     = "16"
}

variable "postgres_database" {
  description = "Application database name."
  type        = string
  default     = "health_node"
}

variable "postgres_app_user" {
  description = "Application PostgreSQL user."
  type        = string
  default     = "health_app"
}

variable "postgres_superuser_password" {
  description = "PostgreSQL superuser password."
  type        = string
  sensitive   = true
}

variable "postgres_app_password" {
  description = "PostgreSQL application user password."
  type        = string
  sensitive   = true
}

variable "postgres_persistence_size" {
  description = "PostgreSQL PVC size."
  type        = string
  default     = "50Gi"
}

variable "postgres_backup_schedule" {
  description = "Cron schedule for PostgreSQL backups."
  type        = string
  default     = "0 2 * * *"
}

variable "postgres_backup_retention_days" {
  description = "Number of days to retain PostgreSQL backup files on the local backup PVC."
  type        = number
  default     = 7
}

variable "postgres_backup_history_limit" {
  description = "Successful job history retained by the PostgreSQL backup CronJob."
  type        = number
  default     = 5
}

variable "postgres_backup_pvc_size" {
  description = "PVC size for PostgreSQL dump backups."
  type        = string
  default     = "20Gi"
}

variable "storage_class" {
  description = "Storage class used for persistent workloads."
  type        = string
  default     = "local-path"
}

variable "pgbouncer_pool_mode" {
  description = "PgBouncer pooling mode."
  type        = string
  default     = "transaction"
}

variable "pgbouncer_max_client_conn" {
  description = "PgBouncer max client connections."
  type        = number
  default     = 500
}

variable "pgbouncer_default_pool_size" {
  description = "PgBouncer default backend pool size."
  type        = number
  default     = 40
}

variable "pgbouncer_reserve_pool_size" {
  description = "PgBouncer reserve backend pool size."
  type        = number
  default     = 10
}
