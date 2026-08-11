locals {
  name_prefix = "trustex-${var.environment}"

  common_labels = {
    project     = "trustex"
    environment = var.environment
    managed_by  = "terraform"
  }

  # Cloud SQL connection name used by Cloud Run's built-in Unix socket connector.
  # Avoids a Serverless VPC Access connector (~$7+/month), which helps the budget.
  cloudsql_connection_name = google_sql_database_instance.main.connection_name

  # Built from variables, not from the repository resource, so image names stay
  # known at plan time even before the registry exists.
  artifact_registry_repository_id = "trustex"
  artifact_registry_url           = "${var.region}-docker.pkg.dev/${var.project_id}/${local.artifact_registry_repository_id}"

  # A *_image override wins; otherwise the image is <registry>/<service>:<tag>.
  frontend_image = var.frontend_image != "" ? var.frontend_image : "${local.artifact_registry_url}/frontend:${var.frontend_tag}"
  backend_image  = var.backend_image != "" ? var.backend_image : "${local.artifact_registry_url}/backend:${var.backend_tag}"
  java_image     = var.java_image != "" ? var.java_image : "${local.artifact_registry_url}/java:${var.java_tag}"

  # ---------------------------------------------------------------------------
  # Env vars from terraform/secrets/{backend,postgres}.
  #
  # Values land in plaintext in terraform state — treat the state as a secret.
  # Files are gitignored and produced by `make secrets-decrypt`.
  # ---------------------------------------------------------------------------

  secrets_env_regex = "(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)$"

  backend_env_file  = "${path.module}/secrets/backend"
  postgres_env_file = "${path.module}/secrets/postgres"

  backend_env_raw  = fileexists(local.backend_env_file) ? file(local.backend_env_file) : ""
  postgres_env_raw = fileexists(local.postgres_env_file) ? file(local.postgres_env_file) : ""

  secrets_backend = {
    for pair in regexall(local.secrets_env_regex, local.backend_env_raw) :
    pair[0] => trimspace(pair[1])
  }

  secrets_postgres = {
    for pair in regexall(local.secrets_env_regex, local.postgres_env_raw) :
    pair[0] => trimspace(pair[1])
  }

  # ---------------------------------------------------------------------------
  # Values Terraform derives from the infrastructure itself. They are unknown
  # until Cloud SQL exists, so Terraform injects them instead of asking you to
  # copy them into the secrets files. Merged last, so they always win: a stale
  # value left in a secrets file cannot point the app at the wrong instance.
  # ---------------------------------------------------------------------------

  cloudsql_derived_env = {
    INSTANCE_CONNECTION_NAME = local.cloudsql_connection_name
    DB_HOST                  = "/cloudsql/${local.cloudsql_connection_name}"
  }

  db_name_effective = lookup(local.secrets_postgres, "DB_NAME", "trustex")

  # Default JDBC URL for the Cloud SQL socket factory. Listed before the secrets
  # files on purpose: override SPRING_DATASOURCE_URL there if you need extra
  # JDBC parameters.
  java_datasource_default = {
    SPRING_DATASOURCE_URL = "jdbc:postgresql:///${local.db_name_effective}?cloudSqlInstance=${local.cloudsql_connection_name}&socketFactory=com.google.cloud.sql.postgres.SocketFactory"
  }

  # Listed before the secrets files so a file can override it.
  debug_env = var.debug ? { DEBUG = "true" } : {}

  # Backend Cloud Run. On a key clash: backend file beats postgres file, and
  # Terraform-derived values beat both.
  backend_service_env = merge(
    local.debug_env,
    local.secrets_postgres,
    local.secrets_backend,
    local.cloudsql_derived_env,
    { JAVA_SERVICE_URL = google_cloud_run_v2_service.java.uri },
  )

  # Java Cloud Run: postgres file plus the derived Cloud SQL values.
  java_service_env = merge(
    local.debug_env,
    local.java_datasource_default,
    local.secrets_postgres,
    local.cloudsql_derived_env,
  )

  frontend_service_env = local.debug_env
}

check "backend_env_file_present" {
  assert {
    condition     = fileexists(local.backend_env_file)
    error_message = "terraform/secrets/backend not found: the backend service will deploy without its env vars. Run `make secrets-decrypt` first."
  }
}

check "postgres_env_file_present" {
  assert {
    condition     = fileexists(local.postgres_env_file)
    error_message = "terraform/secrets/postgres not found: DB-related services will deploy without env vars from that file. Run `make secrets-decrypt` first."
  }
}

check "postgres_db_password_present" {
  assert {
    condition     = lookup(local.secrets_postgres, "DB_PASSWORD", "") != ""
    error_message = "terraform/secrets/postgres must define DB_PASSWORD (used by Cloud SQL and Cloud Run)."
  }
}
