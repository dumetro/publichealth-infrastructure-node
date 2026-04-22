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

  # Airflow connects directly to PostgreSQL (bypassing PgBouncer) to avoid
  # SCRAM/pool-mode compatibility issues with Airflow's internal connection pooler.
  airflow_db_dsn     = "postgresql+psycopg2://${urlencode(var.postgres_app_user)}:${urlencode(var.postgres_app_password)}@postgresql.${var.namespace}.svc.cluster.local:5432/${var.postgres_database}"
  minio_console_host = "console.${var.domain}"
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

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

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

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

# airflow-metadata: the Airflow Helm chart reads data.metadataSecretName = airflow-metadata
# and expects a key named "connection" containing the full SQLAlchemy DSN.
resource "kubernetes_secret" "airflow_metadata" {
  metadata {
    name      = "airflow-metadata"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  data = {
    connection = local.airflow_db_dsn
  }
  type = "Opaque"
}

# airflow-secrets: referenced by extraEnv in airflow-values.yaml for
# fernet_key, webserver_secret_key, and admin_password.
resource "kubernetes_secret" "airflow_secrets" {
  metadata {
    name      = "airflow-secrets"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  data = {
    fernet_key           = var.airflow_fernet_key
    webserver_secret_key = var.airflow_webserver_secret_key
    admin_password       = var.airflow_admin_password
  }
  type = "Opaque"
}

# ---------------------------------------------------------------------------
# 1. Monitoring Stack — deployed first so Prometheus Operator CRDs
#    (ServiceMonitor etc.) are available for ingress-nginx.
# ---------------------------------------------------------------------------

resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [file("${path.module}/../config/values/monitoring-values.yaml")]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
}

# ---------------------------------------------------------------------------
# 2. Ingress Gateway — depends on ServiceMonitor CRD from monitoring.
# ---------------------------------------------------------------------------

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress.metadata[0].name

  values = [file("${path.module}/../config/values/ingress-values.yaml")]

  depends_on = [helm_release.monitoring]
}

# ---------------------------------------------------------------------------
# 3. MinIO — uses official quay.io images (Bitnami registry is paywalled).
#    The standalone console image was deprecated; the built-in console is
#    enabled via MINIO_BROWSER=on and --console-address :9001.
# ---------------------------------------------------------------------------

resource "helm_release" "minio" {
  name       = "minio"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "minio"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [yamlencode({
    global = { security = { allowInsecureImages = true } }
    image = {
      registry   = "quay.io"
      repository = "minio/minio"
      tag        = "RELEASE.2025-09-07T16-13-09Z"
    }
    clientImage = {
      registry   = "quay.io"
      repository = "minio/mc"
      tag        = "latest"
    }
    auth = {
      rootUser         = var.minio_root_user
      rootPassword     = var.minio_root_password
      usePasswordFiles = false
    }
    console = { enabled = false }
    command = ["minio"]
    args    = ["server", "/bitnami/minio/data", "--console-address", ":9001"]

    extraContainerPorts = [{ name = "console", containerPort = 9001 }]
    service = {
      extraPorts = [{ name = "console", port = 9001, targetPort = 9001 }]
    }

    extraEnvVars = [
      { name = "MINIO_BROWSER", value = "on" },
      { name = "MINIO_CONSOLE_ADDRESS", value = ":9001" },
    ]

    apiIngress  = { enabled = false }
    persistence = { size = var.minio_persistence_size }

    networkPolicy = {
      extraIngress = [{ ports = [{ port = 9001, protocol = "TCP" }] }]
    }
  })]

  wait    = true
  timeout = 600

  depends_on = [kubernetes_namespace.data_stack, helm_release.ingress_nginx]
}

# ---------------------------------------------------------------------------
# 4. PostgreSQL — deployed as a plain StatefulSet using the custom
#    postgis+pgvector image. The Bitnami chart expects Bitnami-specific
#    entrypoints that are absent from postgis/postgis-based images.
# ---------------------------------------------------------------------------

resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  spec {
    type     = "ClusterIP"
    selector = { app = "postgresql" }
    port {
      port        = 5432
      target_port = 5432
      name        = "postgresql"
    }
  }
}

resource "kubernetes_stateful_set" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  spec {
    service_name = "postgresql"
    replicas     = 1

    selector {
      match_labels = {
        app                           = "postgresql"
        "app.kubernetes.io/component" = "primary"
        "app.kubernetes.io/instance"  = "postgresql"
      }
    }

    template {
      metadata {
        labels = {
          app                           = "postgresql"
          "app.kubernetes.io/component" = "primary"
          "app.kubernetes.io/instance"  = "postgresql"
        }
      }
      spec {
        security_context { fs_group = 999 }

        container {
          name              = "postgresql"
          image             = "${var.postgres_image_repository}:${var.postgres_image_tag}"
          image_pull_policy = "Never"

          env {
            name  = "POSTGRES_DB"
            value = var.postgres_database
          }
          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_creds.metadata[0].name
                key  = "postgres-password"
              }
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          port { container_port = 5432 }

          readiness_probe {
            exec { command = ["pg_isready", "-U", "postgres"] }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 6
          }
          liveness_probe {
            exec { command = ["pg_isready", "-U", "postgres"] }
            initial_delay_seconds = 30
            period_seconds        = 15
          }

          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }

          volume_mount {
            name       = "postgresql-data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "postgresql-data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class
        resources {
          requests = { storage = var.postgres_persistence_size }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.postgres_creds]
}

# Initialise app user, grant privileges, and enable extensions.
resource "kubernetes_job_v1" "postgres_init" {
  metadata {
    name      = "postgres-init"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }

  spec {
    backoff_limit = 5

    template {
      spec {
        restart_policy = "OnFailure"

        container {
          name              = "postgres-init"
          image             = "${var.postgres_image_repository}:${var.postgres_image_tag}"
          image_pull_policy = "Never"

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_creds.metadata[0].name
                key  = "postgres-password"
              }
            }
          }
          env {
            name = "APP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_creds.metadata[0].name
                key  = "app-password"
              }
            }
          }

          command = ["/bin/bash", "-ec", <<-EOT
            set -euo pipefail
            until pg_isready -h postgresql.${var.namespace}.svc.cluster.local -U postgres; do
              echo "Waiting for PostgreSQL..."; sleep 2
            done
            psql -v ON_ERROR_STOP=1 \
              -h postgresql.${var.namespace}.svc.cluster.local \
              -U postgres -d "${var.postgres_database}" <<SQL
            DO \$\$ BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${var.postgres_app_user}') THEN
                CREATE USER "${var.postgres_app_user}" WITH PASSWORD '$APP_PASSWORD';
              ELSE
                ALTER USER "${var.postgres_app_user}" WITH PASSWORD '$APP_PASSWORD';
              END IF;
            END \$\$;
            GRANT ALL PRIVILEGES ON DATABASE "${var.postgres_database}" TO "${var.postgres_app_user}";
            GRANT ALL ON SCHEMA public TO "${var.postgres_app_user}";
            CREATE EXTENSION IF NOT EXISTS postgis;
            CREATE EXTENSION IF NOT EXISTS vector;
          SQL
          EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts { create = "5m" }

  depends_on = [kubernetes_stateful_set.postgresql, kubernetes_service.postgresql]
}

# ---------------------------------------------------------------------------
# PgBouncer — SCRAM-SHA-256 auth with plain-text userlist.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "pgbouncer_users" {
  metadata {
    name      = "pgbouncer-users"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  data = {
    "userlist.txt" = "\"${var.postgres_app_user}\" \"${var.postgres_app_password}\"\n"
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
      auth_type = scram-sha-256
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
    labels    = { app = "pgbouncer" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "pgbouncer" } }

    template {
      metadata { labels = { app = "pgbouncer" } }
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

          readiness_probe {
            tcp_socket { port = 5432 }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket { port = 5432 }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
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
          config_map { name = kubernetes_config_map.pgbouncer_config.metadata[0].name }
        }
        volume {
          name = "pgbouncer-users"
          secret { secret_name = kubernetes_secret.pgbouncer_users.metadata[0].name }
        }
      }
    }
  }

  depends_on = [
    kubernetes_stateful_set.postgresql,
    kubernetes_job_v1.postgres_init,
  ]
}

resource "kubernetes_service" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  spec {
    selector = { app = "pgbouncer" }
    port {
      name        = "pgbouncer"
      port        = 5432
      target_port = 5432
    }
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL backups
# ---------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim" "postgres_backups" {
  metadata {
    name      = "postgres-backups"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = { storage = var.postgres_backup_pvc_size }
    }
  }
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
              image_pull_policy = "Never"
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.postgres_creds.metadata[0].name
                    key  = "postgres-password"
                  }
                }
              }
              env {
                name  = "POSTGRES_DB"
                value = var.postgres_database
              }
              env {
                name  = "RETENTION_DAYS"
                value = tostring(var.postgres_backup_retention_days)
              }

              command = ["/bin/bash", "-ec", <<-EOT
                set -euo pipefail
                timestamp="$(date +%Y%m%d-%H%M%S)"
                backup_dir="/backups/$POSTGRES_DB"
                mkdir -p "$backup_dir"
                pg_dump -h postgresql.${var.namespace}.svc.cluster.local -U postgres -d "$POSTGRES_DB" -Fc \
                  > "$backup_dir/$POSTGRES_DB-$timestamp.dump"
                pg_dumpall -h postgresql.${var.namespace}.svc.cluster.local -U postgres --globals-only \
                  > "$backup_dir/globals-$timestamp.sql"
                find "$backup_dir" -type f -mtime +"$RETENTION_DAYS" -delete
              EOT
              ]

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

  depends_on = [kubernetes_job_v1.postgres_init]
}

# ---------------------------------------------------------------------------
# 5. Metadata (Unity Catalog — optional)
# ---------------------------------------------------------------------------

resource "helm_release" "unity_catalog" {
  count     = var.deploy_optional_local_charts && local.unity_chart_exists ? 1 : 0
  name      = "unity-catalog"
  chart     = "${path.module}/../charts/unity-catalog"
  namespace = kubernetes_namespace.data_stack.metadata[0].name

  depends_on = [kubernetes_secret.unity_catalog_creds]
}

# ---------------------------------------------------------------------------
# 6. Compute
# ---------------------------------------------------------------------------

resource "helm_release" "spark_operator" {
  name       = "spark-operator"
  repository = "https://kubeflow.github.io/spark-operator"
  chart      = "spark-operator"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [file("${path.module}/../config/values/spark-values.yaml")]

  depends_on = [kubernetes_namespace.data_stack]
}

resource "helm_release" "trino" {
  name       = "trino"
  repository = "https://trinodb.github.io/charts"
  chart      = "trino"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [file("${path.module}/../config/values/trino-values.yaml")]

  set {
    name  = "additionalCatalogs.iceberg"
    value = local.trino_iceberg_catalog
  }

  depends_on = [helm_release.minio]
}

# ---------------------------------------------------------------------------
# 7. Orchestration (Airflow)
#    Ingress is disabled here; created in step 10 below.
#    Airflow connects directly to PostgreSQL (not PgBouncer) to avoid
#    SCRAM/pool-mode compatibility issues.
# ---------------------------------------------------------------------------

resource "helm_release" "airflow" {
  name       = "airflow"
  repository = "https://airflow.apache.org"
  chart      = "airflow"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name
  timeout    = 600

  values = [
    file("${path.module}/../config/values/airflow-values.yaml"),
    yamlencode({
      ingress = {
        web       = { enabled = false }
        apiServer = { enabled = false }
      }
    })
  ]

  depends_on = [
    kubernetes_secret.airflow_metadata,
    kubernetes_secret.airflow_secrets,
    kubernetes_job_v1.postgres_init,
    kubernetes_service.pgbouncer,
  ]
}

# ---------------------------------------------------------------------------
# 8. ML & Workspace
# ---------------------------------------------------------------------------

resource "helm_release" "mlflow" {
  count     = var.deploy_optional_local_charts && local.mlflow_chart_exists ? 1 : 0
  name      = "mlflow"
  chart     = "${path.module}/../charts/mlflow"
  namespace = kubernetes_namespace.data_stack.metadata[0].name

  depends_on = [kubernetes_namespace.data_stack]
}

# JupyterHub — ingress disabled here; created in step 10 below.
resource "helm_release" "jupyterhub" {
  name       = "jupyterhub"
  repository = "https://jupyterhub.github.io/helm-chart/"
  chart      = "jupyterhub"
  namespace  = kubernetes_namespace.data_stack.metadata[0].name

  values = [
    file("${path.module}/../config/values/jupyterhub-values.yaml"),
    yamlencode({ ingress = { enabled = false } })
  ]

  depends_on = [
    kubernetes_secret.minio_creds,
    helm_release.minio,
  ]
}

# ---------------------------------------------------------------------------
# 9. Serving — cert-manager + KServe
# ---------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.certmanager_version
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "crds.enabled"
    value = "true"
  }

  wait    = true
  timeout = 600
}

# KServe is distributed as a single YAML manifest. Terraform's kubernetes
# provider cannot apply arbitrary multi-resource manifests, so we shell out
# to kubectl. The manifest is cached locally to avoid re-downloading.
resource "null_resource" "kserve" {
  provisioner "local-exec" {
    command = <<-EOT
      MANIFEST="${path.module}/../deploy/kserve-${var.kserve_version}.yaml"
      if [ ! -f "$MANIFEST" ]; then
        curl -fsSL "https://github.com/kserve/kserve/releases/download/${var.kserve_version}/kserve.yaml" -o "$MANIFEST"
      fi
      kubectl apply -f "$MANIFEST"
    EOT
  }

  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# 10. Ingress — all service ingresses created after every service is deployed.
#     Managing ingress outside of Helm avoids chart-version ambiguity and
#     nginx admission webhook conflicts.
# ---------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "airflow" {
  metadata {
    name      = "airflow-api-server"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                       = "nginx"
      "nginx.ingress.kubernetes.io/proxy-read-timeout"    = "300"
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" = "60"
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = "airflow.${var.domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "airflow-api-server"
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.airflow, helm_release.ingress_nginx]
}

resource "kubernetes_ingress_v1" "jupyterhub" {
  metadata {
    name      = "jupyterhub"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "300"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "50m"
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = "jupyter.${var.domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "proxy-public"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.jupyterhub, helm_release.ingress_nginx]
}

resource "kubernetes_ingress_v1" "minio_api" {
  metadata {
    name      = "minio-api"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "0"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "600"
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = "minio.${var.domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "minio"
              port { number = 9000 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.minio, helm_release.ingress_nginx]
}

resource "kubernetes_ingress_v1" "minio_console" {
  metadata {
    name      = "minio-console"
    namespace = kubernetes_namespace.data_stack.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "50m"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "300"
      "nginx.ingress.kubernetes.io/proxy-http-version" = "1.1"
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = local.minio_console_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "minio"
              port { number = 9001 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.minio, helm_release.ingress_nginx]
}
