# Database setup as a Cloud Run Job (trustex-web/setup/Dockerfile).
#
# It runs `prisma migrate deploy` and optionally `prisma db seed` against Cloud
# SQL, then exits — see backend/src/setup/setup.service.ts. A job, not a service,
# because Cloud Run has no init containers and the migration must not run once
# per backend instance.
#
# Terraform creates the job but does not execute it: applying infrastructure and
# migrating a database are separate decisions. Run it with `make db-setup`
# (or `gcloud run jobs execute`) after pushing a new backend image.
#
# A job execution is billed only while it runs, so this costs cents per deploy.

resource "google_cloud_run_v2_job" "setup" {
  name     = "${local.name_prefix}-setup"
  location = var.region
  labels   = local.common_labels

  template {
    # A failed migration should surface, not be retried into a half-applied
    # state: Prisma's advisory lock makes retries safe, but a real failure needs
    # eyes on it.
    task_count = 1

    template {
      service_account = google_service_account.setup.email
      max_retries     = 0
      timeout         = "900s"

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [local.cloudsql_connection_name]
        }
      }

      containers {
        image = local.setup_image

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

        dynamic "env" {
          for_each = local.setup_job_env
          content {
            name  = env.key
            value = env.value
          }
        }
      }
    }
  }

  depends_on = [
    time_sleep.api_propagation,
    google_artifact_registry_repository.main,
    google_project_iam_member.setup_ar_reader,
    google_project_iam_member.setup_cloudsql_client,
    google_sql_database.app,
    google_sql_user.app,
  ]
}
