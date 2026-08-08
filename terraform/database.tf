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
    tier              = var.db_tier
    edition           = var.db_edition
    availability_type = "ZONAL"
    disk_type         = var.db_disk_type
    disk_size         = var.db_disk_size_gb
    disk_autoresize   = false

    # Prefer low cost over always-on CPU credits.
    pricing_plan = "PER_USE"

    ip_configuration {
      ipv4_enabled = true
      # No authorized networks: apps connect via the Cloud SQL Auth proxy /
      # Cloud Run built-in connector, not direct public Postgres access.
      require_ssl = true
    }

    backup_configuration {
      enabled                        = var.enable_db_backups
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

  depends_on = [google_project_service.services]
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  name     = var.db_user
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}
