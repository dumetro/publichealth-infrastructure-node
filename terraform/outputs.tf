output "namespace" {
  value       = var.namespace
  description = "Primary namespace hosting the data platform workloads."
}

output "optional_chart_status" {
  value = {
    unity_catalog_available = local.unity_chart_exists
    mlflow_available        = local.mlflow_chart_exists
  }
  description = "Whether optional local chart directories are present in this repo."
}

output "service_endpoints" {
  value = {
    airflow       = "http://airflow.${var.domain}"
    jupyterhub    = "http://jupyter.${var.domain}"
    grafana       = "http://grafana.${var.domain}"
    minio_api     = "http://minio.${var.domain}"
    minio_console = "http://${local.minio_console_host}"
  }
  description = "Web console URLs for deployed services."
}
