# Runtime service accounts for each Cloud Run service (least privilege).

resource "google_service_account" "frontend" {
  account_id   = "${var.name_prefix}-${var.environment}-fe"
  display_name = "Trustex frontend Cloud Run (${var.environment})"
}

resource "google_service_account" "backend" {
  account_id   = "${var.name_prefix}-${var.environment}-be"
  display_name = "Trustex Node.js backend Cloud Run (${var.environment})"
}

resource "google_service_account" "java" {
  account_id   = "${var.name_prefix}-${var.environment}-java"
  display_name = "Trustex Java Cloud Run (${var.environment})"
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

# Secret access for DB password (backend + java only).
resource "google_secret_manager_secret_iam_member" "backend_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_secret_manager_secret_iam_member" "java_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.java.email}"
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
