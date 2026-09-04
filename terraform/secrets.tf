# Keeps a copy of the DB password from terraform/secrets/postgres in Secret
# Manager for ops / break-glass access. Cloud Run no longer reads it: apps get
# DB_PASSWORD from the secrets file via dynamic env.

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${local.name_prefix}-db-password"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_secret_manager_secret_version" "db_password" {
  count = lookup(local.secrets_postgres, "DB_PASSWORD", "") != "" ? 1 : 0

  secret      = google_secret_manager_secret.db_password.id
  secret_data = lookup(local.secrets_postgres, "DB_PASSWORD", "")
}
