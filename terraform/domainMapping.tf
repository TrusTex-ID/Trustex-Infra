# Optional custom domain for the frontend via Cloud Run domain mapping.
# Google-managed SSL certificate is included at no extra LB cost.
# Point a DNS CNAME/A record as instructed in the Terraform outputs.
#
# REGION LIMITATION: domain mapping only exists in asia-east1, asia-northeast1,
# asia-southeast1, europe-north1, europe-west1, europe-west4, us-central1,
# us-east1, us-east4, us-west1. var.region already defaults to europe-west1 for
# this reason; if you move the project to a region outside that list you need the
# load balancer instead. See docs/red-balanceador-y-vpc.md.

resource "google_cloud_run_domain_mapping" "frontend" {
  count = var.frontend_custom_domain != "" ? 1 : 0

  location = var.region
  name     = var.frontend_custom_domain

  metadata {
    namespace = var.project_id
    labels    = local.common_labels
  }

  spec {
    route_name = google_cloud_run_v2_service.frontend.name
  }

  depends_on = [google_cloud_run_v2_service.frontend]
}
