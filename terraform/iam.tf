# Runtime service accounts, one per workload (least privilege).
#
# Only the workloads that talk to Cloud SQL get roles/cloudsql.client: the
# frontend is static nginx and the DSS webapp has no database at all.

# These only reference variables, so nothing links them to iam.googleapis.com.
# Without depends_on they can be created before that API is usable.
resource "google_service_account" "frontend" {
  account_id   = "${local.name_prefix}-fe"
  display_name = "Trustex frontend Cloud Run (${var.environment})"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account" "backend" {
  account_id   = "${local.name_prefix}-be"
  display_name = "Trustex Node.js backend Cloud Run (${var.environment})"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account" "dss" {
  account_id   = "${local.name_prefix}-dss"
  display_name = "Trustex DSS validation Cloud Run (${var.environment})"

  depends_on = [time_sleep.api_propagation]
}

resource "google_service_account" "setup" {
  account_id   = "${local.name_prefix}-setup"
  display_name = "Trustex database setup Cloud Run Job (${var.environment})"

  depends_on = [time_sleep.api_propagation]
}

# Cloud SQL Client — needed for the Cloud Run ↔ Cloud SQL Unix socket connector.
resource "google_project_iam_member" "backend_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "setup_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.setup.email}"
}

# Allow Cloud Run to pull images from Artifact Registry.
resource "google_project_iam_member" "frontend_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.frontend.email}"
}

resource "google_project_iam_member" "backend_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "dss_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.dss.email}"
}

resource "google_project_iam_member" "setup_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.setup.email}"
}
