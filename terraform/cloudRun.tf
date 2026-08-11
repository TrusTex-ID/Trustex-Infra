# Three Cloud Run services with scale-to-zero (min_instances = 0) to stay
# within the ~$20–25/month budget. HTTPS is provided automatically on *.run.app.
# CPU / memory / ports / scaling are fixed here — change them in this file.

resource "google_cloud_run_v2_service" "frontend" {
  name     = "${local.name_prefix}-frontend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.frontend.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = local.frontend_image

      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
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

      dynamic "env" {
        for_each = local.frontend_service_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # The image lives in Artifact Registry and the runtime SA needs the reader role
  # before the revision can pull it. Neither is referenced in the config above.
  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.frontend_ar_reader,
  ]
}

resource "google_cloud_run_v2_service" "backend" {
  name     = "${local.name_prefix}-backend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.backend.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    # Built-in Cloud SQL connector (Unix socket at /cloudsql/INSTANCE)
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }

    containers {
      image = local.backend_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # All env vars come from terraform/secrets/{postgres,backend}.
      dynamic "env" {
        for_each = local.backend_service_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # A revision is only healthy once it can pull its image and reach the database,
  # so the roles, the schema and the DB user must all exist first. None of them
  # are referenced in the config above, hence the explicit list.
  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.backend_ar_reader,
    google_project_iam_member.backend_cloudsql_client,
    google_sql_database.app,
    google_sql_user.app,
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
      min_instance_count = 0
      max_instance_count = 2
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.cloudsql_connection_name]
      }
    }

    containers {
      image = local.java_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # All env vars come from terraform/secrets/postgres.
      dynamic "env" {
        for_each = local.java_service_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.java_ar_reader,
    google_project_iam_member.java_cloudsql_client,
    google_sql_database.app,
    google_sql_user.app,
  ]
}

# Public invokers — browser-facing app.
resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  project  = google_cloud_run_v2_service.frontend.project
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "backend_public" {
  project  = google_cloud_run_v2_service.backend.project
  location = google_cloud_run_v2_service.backend.location
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "java_public" {
  project  = google_cloud_run_v2_service.java.project
  location = google_cloud_run_v2_service.java.location
  name     = google_cloud_run_v2_service.java.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
