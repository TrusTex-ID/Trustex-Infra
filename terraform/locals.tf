locals {
  name_prefix = "${var.name_prefix}-${var.environment}"

  common_labels = merge(
    {
      project     = var.name_prefix
      environment = var.environment
      managed_by  = "terraform"
    },
    var.labels,
  )

  # Cloud SQL connection name used by Cloud Run's built-in Unix socket connector.
  # Avoids a Serverless VPC Access connector (~$7+/month), which helps the budget.
  cloudsql_connection_name = google_sql_database_instance.main.connection_name

  artifact_registry_url = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
}
