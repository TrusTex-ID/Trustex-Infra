# Runtime service accounts for each Cloud Run service (least privilege).

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

resource "google_service_account" "java" {
  account_id   = "${local.name_prefix}-java"
  display_name = "Trustex Java Cloud Run (${var.environment})"

  depends_on = [time_sleep.api_propagation]
}

# Cloud SQL Client — needed for the Cloud Run ↔ Cloud SQL Unix socket connector.
resource "google_project_iam_member" "backend_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "java_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.java.email}"
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

resource "google_project_iam_member" "java_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.java.email}"
}
