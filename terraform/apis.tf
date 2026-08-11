# Required Google APIs for Trustex infrastructure.
# Enabling them via Terraform avoids manual console setup.

resource "google_project_service" "services" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Enabling an API returns before it is usable, so the first apply on a fresh
# project fails with "API has not been used in project ... before or it is
# disabled". Every resource depends on this instead of on the services directly.
# It only sleeps on create, so later applies are not slowed down.
resource "time_sleep" "api_propagation" {
  depends_on = [google_project_service.services]

  create_duration = "60s"
}
