# Budget-oriented Cloud SQL Postgres:
# - Shared-core db-f1-micro
# - Small HDD disk
# - Zonal (no HA)
# - Public IP + Cloud Run Cloud SQL connector (no VPC connector cost)
# Expect roughly ~$8–12/month depending on region and storage.

resource "google_sql_database_instance" "main" {
  name             = "${local.name_prefix}-pg"
  database_version = "POSTGRES_15"
  region           = var.region

  # Prevent accidental destroy. Override to false in tfvars for disposable dev envs.
  deletion_protection = var.environment == "prod"

  settings {
    # Fixed budget profile (~$8–12/month). Change here if you need more capacity.
    tier              = "db-f1-micro" # shared-core, ~0.6 GB RAM
    edition           = "ENTERPRISE"  # required for db-f1-micro
    availability_type = "ZONAL"      # no HA replica
    disk_type         = "PD_HDD"
    disk_size         = 10 # GB
    disk_autoresize   = false
    pricing_plan      = "PER_USE"

    dynamic "location_preference" {
      for_each = var.zone != "" ? [var.zone] : []
      content {
        zone = location_preference.value
      }
    }

    ip_configuration {
      ipv4_enabled = true
      # No authorized networks: apps connect via the Cloud SQL Auth proxy /
      # Cloud Run built-in connector, not direct public Postgres access.
      require_ssl = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = false
      backup_retention_settings {
        retained_backups = 3
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    database_flags {
      name  = "max_connections"
      value = "50"
    }

    user_labels = local.common_labels
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_sql_database" "app" {
  # Prefer values from terraform/secrets/postgres so Cloud SQL and Cloud Run stay aligned.
  name     = lookup(local.secrets_postgres, "DB_NAME", "trustex")
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  name     = lookup(local.secrets_postgres, "DB_USER", "trustex")
  instance = google_sql_database_instance.main.name
  password = lookup(local.secrets_postgres, "DB_PASSWORD", null)

  lifecycle {
    precondition {
      condition     = lookup(local.secrets_postgres, "DB_PASSWORD", "") != ""
      error_message = "terraform/secrets/postgres must define DB_PASSWORD before creating the Cloud SQL user. Run `make secrets-decrypt` and set it."
    }
  }
}
