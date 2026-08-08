# Three Cloud Run services with scale-to-zero (min_instances = 0) to stay
# within the ~$20–25/month budget. HTTPS is provided automatically on *.run.app.

resource "google_cloud_run_v2_service" "frontend" {
  name     = "${local.name_prefix}-frontend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.frontend.email

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    containers {
      image = var.frontend_image

      ports {
        container_port = var.frontend_port
      }

      resources {
        limits = {
          cpu    = var.frontend_cpu
          memory = var.frontend_memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "NODE_ENV"
        value = var.environment == "prod" ? "production" : "development"
      }

      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend.uri
      }

      env {
        name  = "JAVA_URL"
        value = google_cloud_run_v2_service.java.uri
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [google_project_service.services]
}

resource "google_cloud_run_v2_service" "backend" {
  name     = "${local.name_prefix}-backend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.backend.email

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    # Built-in Cloud SQL connector (Unix socket at /cloudsql/INSTANCE)
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }

    containers {
      image = var.backend_image

      ports {
        container_port = var.backend_port
      }

      resources {
        limits = {
          cpu    = var.backend_cpu
          memory = var.backend_memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "NODE_ENV"
        value = var.environment == "prod" ? "production" : "development"
      }

      env {
        name  = "DB_HOST"
        value = "/cloudsql/${local.cloudsql_connection_name}"
      }

      env {
        name  = "DB_NAME"
        value = var.db_name
      }

      env {
        name  = "DB_USER"
        value = var.db_user
      }

      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = local.cloudsql_connection_name
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "JAVA_SERVICE_URL"
        value = google_cloud_run_v2_service.java.uri
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.services,
    google_secret_manager_secret_version.db_password,
    google_sql_database_instance.main,
  ]
}

resource "google_cloud_run_v2_service" "java" {
  name     = "${local.name_prefix}-java"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.java.email

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }

    containers {
      image = var.java_image

      ports {
        container_port = var.java_port
      }

      resources {
        limits = {
          cpu    = var.java_cpu
          memory = var.java_memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = var.environment
      }

      env {
        name  = "SPRING_DATASOURCE_URL"
        value = "jdbc:postgresql:///${var.db_name}?cloudSqlInstance=${local.cloudsql_connection_name}&socketFactory=com.google.cloud.sql.postgres.SocketFactory"
      }

      env {
        name  = "SPRING_DATASOURCE_USERNAME"
        value = var.db_user
      }

      env {
        name = "SPRING_DATASOURCE_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = local.cloudsql_connection_name
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.services,
    google_secret_manager_secret_version.db_password,
    google_sql_database_instance.main,
  ]
}

# Public invokers (optional). Required for a browser-facing frontend.
resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = google_cloud_run_v2_service.frontend.project
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "backend_public" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = google_cloud_run_v2_service.backend.project
  location = google_cloud_run_v2_service.backend.location
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "java_public" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = google_cloud_run_v2_service.java.project
  location = google_cloud_run_v2_service.java.location
  name     = google_cloud_run_v2_service.java.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
