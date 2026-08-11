# Optional Global External HTTPS Load Balancer in front of Cloud Run.
#
# COST WARNING: A global forwarding rule alone is roughly ~$18/month.
# Combined with Cloud SQL this usually exceeds the $20–25 budget.
# Keep var.enable_load_balancer = false unless you accept the extra cost.
# Prefer domain_mapping.tf for a custom domain within budget.

locals {
  lb_enabled = var.enable_load_balancer
}

check "load_balancer_requires_domains" {
  assert {
    condition     = !var.enable_load_balancer || length(var.lb_domains) > 0
    error_message = "When enable_load_balancer is true, lb_domains must contain at least one domain for the managed certificate."
  }
}

resource "google_compute_region_network_endpoint_group" "frontend" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-fe-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.frontend.name
  }
}

resource "google_compute_region_network_endpoint_group" "backend" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-be-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.backend.name
  }
}

resource "google_compute_region_network_endpoint_group" "java" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-java-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.java.name
  }
}

resource "google_compute_backend_service" "frontend" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-fe-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.frontend[0].id
  }
}

resource "google_compute_backend_service" "backend" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-be-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.backend[0].id
  }
}

resource "google_compute_backend_service" "java" {
  count = local.lb_enabled ? 1 : 0

  name                  = "${local.name_prefix}-java-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.java[0].id
  }
}

resource "google_compute_url_map" "main" {
  count = local.lb_enabled ? 1 : 0

  name            = "${local.name_prefix}-url-map"
  default_service = google_compute_backend_service.frontend[0].id

  host_rule {
    hosts        = ["*"]
    path_matcher = "services"
  }

  path_matcher {
    name            = "services"
    default_service = google_compute_backend_service.frontend[0].id

    path_rule {
      paths   = ["/api/*", "/api"]
      service = google_compute_backend_service.backend[0].id
    }

    path_rule {
      paths   = ["/java/*", "/java"]
      service = google_compute_backend_service.java[0].id
    }
  }
}

# The three resources below reference no other resource, so they need an explicit
# dependency on compute.googleapis.com being usable. The rest of the load
# balancer reaches it transitively through the Cloud Run services and NEGs.
resource "google_compute_managed_ssl_certificate" "main" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name = "${local.name_prefix}-cert"

  managed {
    domains = var.lb_domains
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_compute_target_https_proxy" "main" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name             = "${local.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.main[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.main[0].id]
}

resource "google_compute_global_address" "lb" {
  count = local.lb_enabled ? 1 : 0

  name = "${local.name_prefix}-lb-ip"

  depends_on = [time_sleep.api_propagation]
}

resource "google_compute_global_forwarding_rule" "https" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name                  = "${local.name_prefix}-https-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.main[0].id
  ip_address            = google_compute_global_address.lb[0].id
}

# HTTP → HTTPS redirect when LB + certificate are enabled.
resource "google_compute_url_map" "http_redirect" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name = "${local.name_prefix}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_compute_target_http_proxy" "redirect" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name    = "${local.name_prefix}-http-proxy"
  url_map = google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http" {
  count = local.lb_enabled && length(var.lb_domains) > 0 ? 1 : 0

  name                  = "${local.name_prefix}-http-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect[0].id
  ip_address            = google_compute_global_address.lb[0].id
}
