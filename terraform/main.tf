locals {
  unity_chart_exists  = fileexists("${path.module}/../charts/unity-catalog/Chart.yaml")
  mlflow_chart_exists = fileexists("${path.module}/../charts/mlflow/Chart.yaml")
  pgbouncer_app_md5   = "md5${md5(join("", [var.postgres_app_password, var.postgres_app_user]))}"

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

resource "kubernetes_secret" "postgres_creds" {
  metadata {
    name      = "postgres-creds"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    postgres-password = var.postgres_superuser_password
    app-password      = var.postgres_app_password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "airflow_secrets" {
  metadata {
    name      = "airflow-secrets"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    sql_alchemy_conn     = "postgresql+psycopg2://${urlencode(var.postgres_app_user)}:${urlencode(var.postgres_app_password)}@pgbouncer.${var.namespace}.svc.cluster.local:5432/${var.postgres_database}"
    fernet_key           = var.airflow_fernet_key
    webserver_secret_key = var.airflow_webserver_secret_key
    admin_password       = var.airflow_admin_password
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

resource "helm_release" "postgresql" {
  name       = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/postgres-values.yaml")
  ]

  set {
    name  = "image.repository"
    value = var.postgres_image_repository
  }

  set {
    name  = "image.tag"
    value = var.postgres_image_tag
  }

  set {
    name  = "auth.username"
    value = var.postgres_app_user
  }

  set {
    name  = "auth.database"
    value = var.postgres_database
  }

  set_sensitive {
    name  = "auth.postgresPassword"
    value = var.postgres_superuser_password
  }

  set_sensitive {
    name  = "auth.password"
    value = var.postgres_app_password
  }

  set {
    name  = "primary.persistence.storageClass"
    value = var.storage_class
  }

  set {
    name  = "primary.persistence.size"
    value = var.postgres_persistence_size
  }

  depends_on = [
    kubernetes_namespace.data_stack,
    kubernetes_secret.postgres_creds,
  ]
}

resource "kubernetes_secret" "pgbouncer_users" {
  metadata {
    name      = "pgbouncer-users"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    "userlist.txt" = "\"${var.postgres_app_user}\" \"${local.pgbouncer_app_md5}\"\n"
  }

  type = "Opaque"
}

resource "kubernetes_config_map" "pgbouncer_config" {
  metadata {
    name      = "pgbouncer-config"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  data = {
    "pgbouncer.ini" = <<-EOT
      [databases]
      * = host=postgresql.${var.namespace}.svc.cluster.local port=5432

      [pgbouncer]
      listen_addr = 0.0.0.0
      listen_port = 5432
      auth_type = md5
      auth_file = /etc/pgbouncer/userlist.txt
      pool_mode = ${var.pgbouncer_pool_mode}
      max_client_conn = ${var.pgbouncer_max_client_conn}
      default_pool_size = ${var.pgbouncer_default_pool_size}
      reserve_pool_size = ${var.pgbouncer_reserve_pool_size}
      server_reset_query = DISCARD ALL
      ignore_startup_parameters = extra_float_digits
      admin_users = ${var.postgres_app_user}
      stats_users = ${var.postgres_app_user}
    EOT
  }
}

resource "kubernetes_deployment" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
    labels = {
      app = "pgbouncer"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "pgbouncer"
      }
    }

    template {
      metadata {
        labels = {
          app = "pgbouncer"
        }
      }

      spec {
        container {
          name              = "pgbouncer"
          image             = "edoburu/pgbouncer:v1.23.1-p3"
          image_pull_policy = "IfNotPresent"
          command           = ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]

          port {
            container_port = 5432
            name           = "pgbouncer"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "pgbouncer-config"
            mount_path = "/etc/pgbouncer/pgbouncer.ini"
            sub_path   = "pgbouncer.ini"
          }

          volume_mount {
            name       = "pgbouncer-users"
            mount_path = "/etc/pgbouncer/userlist.txt"
            sub_path   = "userlist.txt"
          }
        }

        volume {
          name = "pgbouncer-config"
          config_map {
            name = kubernetes_config_map.pgbouncer_config.metadata[0].name
          }
        }

        volume {
          name = "pgbouncer-users"
          secret {
            secret_name = kubernetes_secret.pgbouncer_users.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.postgresql,
    kubernetes_config_map.pgbouncer_config,
    kubernetes_secret.pgbouncer_users,
  ]
}

resource "kubernetes_service" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  spec {
    selector = {
      app = "pgbouncer"
    }

    port {
      name        = "pgbouncer"
      port        = 5432
      target_port = 5432
    }
  }

  depends_on = [kubernetes_deployment.pgbouncer]
}

resource "kubernetes_persistent_volume_claim" "postgres_backups" {
  metadata {
    name      = "postgres-backups"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = var.postgres_backup_pvc_size
      }
    }
  }

  depends_on = [kubernetes_namespace.data_stack]
}

resource "kubernetes_job_v1" "postgres_enable_extensions" {
  metadata {
    name      = "postgres-enable-extensions"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  spec {
    backoff_limit = 3

    template {
      spec {
        restart_policy = "OnFailure"

        container {
          name              = "postgres-enable-extensions"
          image             = "${var.postgres_image_repository}:${var.postgres_image_tag}"
          image_pull_policy = "IfNotPresent"
          command = [
            "/bin/bash",
            "-ec",
            <<-EOT
              set -euo pipefail
              psql -v ON_ERROR_STOP=1 -h postgresql.${var.namespace}.svc.cluster.local -U postgres -d "${var.postgres_database}" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS vector;"
            EOT
          ]

          env {
            name = "PGPASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_creds.metadata[0].name
                key  = "postgres-password"
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  depends_on = [
    helm_release.postgresql,
    kubernetes_secret.postgres_creds,
  ]
}

resource "kubernetes_cron_job_v1" "postgres_backup" {
  metadata {
    name      = "postgres-backup"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  spec {
    schedule                      = var.postgres_backup_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = var.postgres_backup_history_limit
    failed_jobs_history_limit     = 3

    job_template {
      spec {
        template {
          spec {
            restart_policy = "OnFailure"

            container {
              name              = "postgres-backup"
              image             = "${var.postgres_image_repository}:${var.postgres_image_tag}"
              image_pull_policy = "IfNotPresent"
              command = [
                "/bin/bash",
                "-ec",
                <<-EOT
                  set -euo pipefail
                  timestamp="$(date +%Y%m%d-%H%M%S)"
                  backup_dir="/backups/${var.postgres_database}"
                  mkdir -p "$backup_dir"
                  pg_dump -h postgresql.${var.namespace}.svc.cluster.local -U postgres -d "${var.postgres_database}" -Fc > "$backup_dir/${var.postgres_database}-${timestamp}.dump"
                  pg_dumpall -h postgresql.${var.namespace}.svc.cluster.local -U postgres --globals-only > "$backup_dir/globals-${timestamp}.sql"
                  find "$backup_dir" -type f -mtime +"${var.postgres_backup_retention_days}" -delete
                EOT
              ]

              env {
                name = "PGPASSWORD"

                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.postgres_creds.metadata[0].name
                    key  = "postgres-password"
                  }
                }
              }

              volume_mount {
                name       = "postgres-backups"
                mount_path = "/backups"
              }
            }

            volume {
              name = "postgres-backups"

              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.postgres_backups.metadata[0].name
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.postgresql,
    kubernetes_job_v1.postgres_enable_extensions,
    kubernetes_persistent_volume_claim.postgres_backups,
    kubernetes_secret.postgres_creds,
  ]
}

resource "helm_release" "spark_operator" {
  name       = "spark-operator"
  repository = "https://kubeflow.github.io/spark-operator"
  chart      = "spark-operator"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/spark-values.yaml")
  ]

  depends_on = [
    kubernetes_namespace.data_stack,
    helm_release.postgresql,
  ]
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

  values = [
    file("${path.module}/../config/values/airflow-values.yaml")
  ]

  depends_on = [
    kubernetes_namespace.data_stack,
    kubernetes_secret.airflow_secrets,
    kubernetes_secret.postgres_creds,
    kubernetes_service.pgbouncer,
  ]
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
