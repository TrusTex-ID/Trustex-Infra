# Required Google APIs for Trustex infrastructure.
# Enabling them via Terraform avoids manual console setup.

resource "google_project_service" "services" {
  for_each = toset(concat([
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    # Needed by the optional load balancer and by Cloud Run domain mapping.
    "compute.googleapis.com",
    ],
    # Only reachable when a billing budget is actually requested: enabling it
    # needs billing-account permissions that a plain project owner may not have.
    var.billing_account_id != "" ? ["billingbudgets.googleapis.com"] : [],
    # Only the optional email notification channels in budget.tf need this, and
    # they are only created when there are addresses to notify.
    var.billing_account_id != "" && length(var.budget_alert_emails) > 0 ? ["monitoring.googleapis.com"] : [],
  ))

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
