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

variable "debug" {
  description = "Injects DEBUG=true into the Cloud Run services. The secrets files can override it."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name used for resource naming and labels."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# Cloud Run images
# ---------------------------------------------------------------------------

# Image tags are the normal way to pick a version: the Artifact Registry path is
# derived from project_id, region and the fixed repository name. Set the *_image
# override only to point at an image outside this registry (for example the
# Cloud Run hello placeholder on the very first apply, when the repo is empty).

variable "frontend_tag" {
  description = "Image tag for the Next.js frontend in Artifact Registry."
  type        = string
  default     = "latest"
}

variable "backend_tag" {
  description = "Image tag for the Node.js backend in Artifact Registry."
  type        = string
  default     = "latest"
}

variable "java_tag" {
  description = "Image tag for the Spring Boot service in Artifact Registry."
  type        = string
  default     = "latest"
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

variable "java_image" {
  description = "Full image override for the Java service. Empty means build it from java_tag."
  type        = string
  default     = ""
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
