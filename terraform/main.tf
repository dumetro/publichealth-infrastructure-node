locals {
  unity_chart_exists  = fileexists("${path.module}/../charts/unity-catalog/Chart.yaml")
  mlflow_chart_exists = fileexists("${path.module}/../charts/mlflow/Chart.yaml")

  trino_iceberg_catalog = <<-EOT
    connector.name=iceberg
    iceberg.catalog.type=rest
    iceberg.rest-catalog.uri=http://unity-catalog.${var.namespace}.svc.cluster.local:8080/api/2.1/unity-catalog/iceberg
    iceberg.rest-catalog.security=OAUTH2
    iceberg.rest-catalog.oauth2.token=${var.unity_catalog_admin_token}
    fs.native-s3.enabled=true
    s3.endpoint=http://minio.${var.namespace}.svc.cluster.local:9000
    s3.path-style-access=true
  EOT
}

resource "kubernetes_namespace" "data_stack" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_namespace" "ingress" {
  metadata {
    name = "ingress-basic"
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_secret" "minio_creds" {
  metadata {
    name      = "minio-creds"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    access-key = var.minio_root_user
    secret-key = var.minio_root_password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "unity_catalog_creds" {
  metadata {
    name      = "unity-catalog-creds"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    access-token = var.unity_catalog_admin_token
  }

  type = "Opaque"
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress.metadata[0].name

  values = [
    file("${path.module}/../config/values/ingress-values.yaml")
  ]
}

resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    file("${path.module}/../config/values/monitoring-values.yaml")
  ]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  depends_on = [kubernetes_namespace.monitoring]
}

resource "helm_release" "minio" {
  name       = "minio"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "minio"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  set {
    name  = "auth.rootUser"
    value = var.minio_root_user
  }

  set_sensitive {
    name  = "auth.rootPassword"
    value = var.minio_root_password
  }

  set {
    name  = "defaultBuckets"
    value = join(",", var.minio_buckets)
  }

  depends_on = [kubernetes_namespace.data_stack]
}

resource "helm_release" "spark_operator" {
  name       = "spark-operator"
  repository = "https://kubeflow.github.io/spark-operator"
  chart      = "spark-operator"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/spark-values.yaml")
  ]

  depends_on = [kubernetes_namespace.data_stack]
}

resource "helm_release" "trino" {
  name       = "trino"
  repository = "https://trinodb.github.io/charts"
  chart      = "trino"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/trino-values.yaml")
  ]

  set {
    name  = "additionalCatalogs.iceberg"
    value = local.trino_iceberg_catalog
  }

  depends_on = [helm_release.minio]
}

resource "helm_release" "airflow" {
  name       = "airflow"
  repository = "https://airflow.apache.org"
  chart      = "airflow"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  depends_on = [kubernetes_namespace.data_stack]
}

resource "helm_release" "jupyterhub" {
  name       = "jupyterhub"
  repository = "https://jupyterhub.github.io/helm-chart/"
  chart      = "jupyterhub"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/jupyterhub-values.yaml")
  ]

  set {
    name  = "ingress.hosts[0]"
    value = "jupyter.${var.domain}"
  }

  depends_on = [
    kubernetes_secret.minio_creds,
    helm_release.minio,
  ]
}

resource "helm_release" "unity_catalog" {
  count     = var.deploy_optional_local_charts && local.unity_chart_exists ? 1 : 0
  name      = "unity-catalog"
  chart     = "${path.module}/../charts/unity-catalog"
  namespace = kubernetes_namespace.data_stack.metadata[0].name

  depends_on = [kubernetes_secret.unity_catalog_creds]
}

resource "helm_release" "mlflow" {
  count     = var.deploy_optional_local_charts && local.mlflow_chart_exists ? 1 : 0
  name      = "mlflow"
  chart     = "${path.module}/../charts/mlflow"
  namespace = kubernetes_namespace.data_stack.metadata[0].name

  depends_on = [kubernetes_namespace.data_stack]
}
