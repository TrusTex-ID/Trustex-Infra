variable "project_id" {
  description = "GCP project ID where Trustex infrastructure will be deployed."
  type        = string
}

variable "region" {
  description = "Primary GCP region for regional resources."
  type        = string
  default     = "europe-west1" # Belgium — one of the regions with Cloud Run domain mapping
}

variable "zone" {
  description = "Zone used to pin the zonal Cloud SQL instance. Empty lets GCP choose."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment name used for resource naming and labels."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------

# Image tags are the normal way to pick a version: the Artifact Registry path is
# derived from project_id, region and the fixed repository name. Set the *_image
# override only to point at an image outside this registry (for example the
# Cloud Run hello placeholder on the very first apply, when the repo is empty).
#
# The tag is what actually deploys. Cloud Run pins the image string in the
# revision template, so bumping one of these is what makes Terraform create a new
# revision — and a mutable tag like `latest` breaks that: the string never
# changes, Terraform sees no diff, and a freshly pushed image is never rolled
# out. Hence the validation below, shared by all four.
#
# Keep these in step with the tags actually pushed (Makefile: TAG, or the
# per-image FRONTEND_TAG / BACKEND_TAG / DSS_TAG / SETUP_TAG).

variable "frontend_tag" {
  description = "Image tag for the React/Vite SPA served by nginx (trustex-web/frontend)."
  type        = string
  default     = "0.0.1"

  validation {
    condition     = var.frontend_tag != "latest"
    error_message = "Use an immutable version tag (0.0.1, 0.0.2, ...), not `latest`: the image string would never change, so Terraform would deploy no new revision."
  }
}

variable "backend_tag" {
  description = "Image tag for the Express + Prisma backend (trustex-web/backend)."
  type        = string
  default     = "0.0.1"

  validation {
    condition     = var.backend_tag != "latest"
    error_message = "Use an immutable version tag (0.0.1, 0.0.2, ...), not `latest`: the image string would never change, so Terraform would deploy no new revision."
  }
}

variable "dss_tag" {
  description = "Image tag for the EU DSS signature validation webapp (dss-validation-docker)."
  type        = string
  default     = "0.0.1"

  validation {
    condition     = var.dss_tag != "latest"
    error_message = "Use an immutable version tag (0.0.1, 0.0.2, ...), not `latest`: the image string would never change, so Terraform would deploy no new revision."
  }
}

variable "setup_tag" {
  description = "Image tag for the database setup job (trustex-web/setup)."
  type        = string
  default     = "0.0.1"

  validation {
    condition     = var.setup_tag != "latest"
    error_message = "Use an immutable version tag (0.0.1, 0.0.2, ...), not `latest`: the image string would never change, so Terraform would deploy no new revision."
  }
}

variable "frontend_image" {
  description = "Full image override for the frontend. Empty means build it from frontend_tag."
  type        = string
  default     = ""
}

variable "backend_image" {
  description = "Full image override for the backend. Empty means build it from backend_tag."
  type        = string
  default     = ""
}

variable "dss_image" {
  description = "Full image override for the DSS service. Empty means build it from dss_tag."
  type        = string
  default     = ""
}

variable "setup_image" {
  description = "Full image override for the setup job. Empty means build it from setup_tag."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Frontend
# ---------------------------------------------------------------------------

variable "frontend_public_url" {
  description = <<-EOT
    Public origin the browser uses to reach the frontend, injected into the
    backend as FRONTEND_URL (its CORS allow-origin). Only needed if something
    calls the backend's own run.app URL cross-origin; the SPA itself goes through
    the frontend's same-origin /api/v1 proxy. Defaults to
    https://<frontend_custom_domain> when that is set, otherwise unset.
    Cannot be derived from the frontend service without a dependency cycle:
    read it from the `frontend_url` output after the first apply.
  EOT
  type        = string
  default     = ""
}

# VITE_DPP_BASE_URL is deliberately NOT a variable here. Vite inlines VITE_*
# into the JS bundle at build time, so Terraform cannot set it: it is a
# `docker build --build-arg`, and its single source of truth is DPP_BASE_URL in
# the Makefile. Declaring it here too only invited the two to drift apart, since
# an `apply` could never act on it. See docs/variables-de-entorno.md.

# ---------------------------------------------------------------------------
# DSS validation service
# ---------------------------------------------------------------------------

variable "dss_public_invoker" {
  description = <<-EOT
    Grant roles/run.invoker to allUsers on the DSS service.

    Default false, matching the service's own deployment guide
    (--no-allow-unauthenticated): the image also serves a web UI, Swagger, the
    SOAP endpoints and /server-sign/**, which signs with a demo keystore whose
    password is public. Only the backend service account should reach it.

    That requires the caller to send an OIDC ID token, which
    trustex-web/backend/src/verification/dss-client.ts does: it mints one with
    google-auth-library and sends it as Authorization: Bearer, falling back to
    an unauthenticated call only where no token can be obtained (local
    docker-compose, which has no IAM in front). Leave this false — true is only
    an escape hatch for debugging. See docs/apps-y-servicios.md.
  EOT
  type        = bool
  default     = false
}

variable "dss_min_instances" {
  description = <<-EOT
    Warm instances for the DSS service, and with it the deployment mode from the
    service's own docs:

      0 (Mode A, default) — scale to zero, CPU throttled between requests.
        Nearly free. Correct only because the image ships a pre-warmed LOTL
        cache, loaded during @PostConstruct where Cloud Run grants full CPU.
        Cold start is roughly 40-90s.

      1+ (Mode B) — always warm, CPU always allocated (cloudRun.tf derives that
        from this value; the two are inseparable). No cold start and the hourly
        trusted-list refresh actually runs, but a 2 vCPU / 4 GiB instance billed
        24/7 is on the order of $90-120/month — far past the project budget.
  EOT
  type        = number
  default     = 0
}

# ---------------------------------------------------------------------------
# Database setup job (trustex-web/setup — prisma migrate deploy / db seed)
# ---------------------------------------------------------------------------

variable "setup_run_migrations" {
  description = "SETUP_RUN_MIGRATIONS for the setup job: apply pending Prisma migrations."
  type        = bool
  default     = true
}

variable "setup_run_seed" {
  description = "SETUP_RUN_SEED for the setup job: run prisma db seed. Off by default — it is not idempotent in general."
  type        = bool
  default     = false
}

variable "setup_db_wait_retries" {
  description = "SETUP_DB_WAIT_RETRIES: attempts to reach the database before giving up."
  type        = number
  default     = 10

  validation {
    condition     = var.setup_db_wait_retries > 0 && var.setup_db_wait_retries <= 60
    error_message = "setup_db_wait_retries must be between 1 and 60 (enforced by backend/src/setup/setup.config.ts)."
  }
}

variable "setup_db_wait_delay_ms" {
  description = "SETUP_DB_WAIT_DELAY_MS: delay between database connection attempts."
  type        = number
  default     = 3000

  validation {
    condition     = var.setup_db_wait_delay_ms > 0 && var.setup_db_wait_delay_ms <= 60000
    error_message = "setup_db_wait_delay_ms must be between 1 and 60000 (enforced by backend/src/setup/setup.config.ts)."
  }
}

# ---------------------------------------------------------------------------
# Optional custom domain (Cloud Run domain mapping — free managed SSL)
# Prefer this over a Global HTTPS LB to stay within ~$20–25/month.
# ---------------------------------------------------------------------------

variable "frontend_custom_domain" {
  description = "Optional custom domain for the frontend (e.g. app.example.com). Leave empty to skip."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Optional Global HTTPS Load Balancer
# WARNING: A global forwarding rule alone is ~$18/month and will usually
# push total spend above the $20–25 budget when combined with Cloud SQL.
# Keep disabled unless you accept the extra cost.
# ---------------------------------------------------------------------------

variable "enable_load_balancer" {
  description = "Provision a Global HTTPS Load Balancer in front of Cloud Run. Expensive; off by default. Requires lb_domains."
  type        = bool
  default     = false
}

variable "lb_domains" {
  description = "Domains for the managed SSL certificate when the load balancer is enabled."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Billing budget
#
# The whole configuration is shaped by a hard ~$20-25/month ceiling, and until
# now nothing watched it. A budget with alerts costs nothing; it is off by
# default only because creating one needs permissions on the billing account
# (roles/billing.costsManager or similar), which a plain project owner may lack.
# ---------------------------------------------------------------------------

variable "billing_account_id" {
  description = "Billing account ID (e.g. 000000-AAAAAA-BBBBBB) used to create a budget alert. Empty disables the budget."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget in budget_currency. Alerts fire at the thresholds below, they never cap spend."
  type        = number
  default     = 25
}

variable "budget_currency" {
  description = "Currency code for budget_amount. Must match the billing account's currency."
  type        = string
  default     = "EUR"
}

variable "budget_alert_emails" {
  description = <<-EOT
    Extra addresses to notify. Empty means only the billing account admins and
    project owners are notified, which is the default Cloud Billing behaviour
    and is usually enough for a one-person project.
  EOT
  type        = list(string)
  default     = []
}
