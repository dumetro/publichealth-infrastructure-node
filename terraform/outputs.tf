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
