variable "project_id" {
  description = "GCP project ID where Trustex infrastructure will be deployed."
  type        = string
}

variable "region" {
  description = "Primary GCP region for regional resources."
  type        = string
  default     = "europe-southwest1" # Madrid — usually cheaper egress for EU users
}

variable "environment" {
  description = "Environment name used for resource naming and labels."
  type        = string
  default     = "dev"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "trustex"
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------

variable "artifact_registry_repository_id" {
  description = "Artifact Registry repository ID for container images."
  type        = string
  default     = "trustex"
}

# ---------------------------------------------------------------------------
# Cloud SQL (budget-oriented defaults)
# ---------------------------------------------------------------------------

variable "db_tier" {
  description = "Cloud SQL machine tier. db-f1-micro keeps monthly cost low."
  type        = string
  default     = "db-f1-micro"
}

variable "db_disk_size_gb" {
  description = "Cloud SQL disk size in GB. Keep small for budget."
  type        = number
  default     = 10
}

variable "db_disk_type" {
  description = "Cloud SQL disk type. PD_HDD is cheaper than PD_SSD."
  type        = string
  default     = "PD_HDD"
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "trustex"
}

variable "db_user" {
  description = "Application database user."
  type        = string
  default     = "trustex"
}

variable "db_edition" {
  description = "Cloud SQL edition. ENTERPRISE is required for db-f1-micro."
  type        = string
  default     = "ENTERPRISE"
}

variable "enable_db_backups" {
  description = "Enable automated Cloud SQL backups (small storage cost)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Cloud Run images & runtime
# ---------------------------------------------------------------------------

variable "frontend_image" {
  description = "Container image for the Next.js frontend. Defaults to a hello placeholder until you push your image."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "backend_image" {
  description = "Container image for the Node.js backend. Defaults to a hello placeholder until you push your image."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "java_image" {
  description = "Container image for the Spring Boot service. Defaults to a hello placeholder until you push your image."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "cloud_run_min_instances" {
  description = "Minimum Cloud Run instances. 0 enables scale-to-zero (required for the budget)."
  type        = number
  default     = 0
}

variable "cloud_run_max_instances" {
  description = "Maximum Cloud Run instances per service."
  type        = number
  default     = 2
}

variable "frontend_cpu" {
  description = "vCPU for the frontend Cloud Run service."
  type        = string
  default     = "1"
}

variable "frontend_memory" {
  description = "Memory for the frontend Cloud Run service."
  type        = string
  default     = "512Mi"
}

variable "backend_cpu" {
  description = "vCPU for the Node.js backend Cloud Run service."
  type        = string
  default     = "1"
}

variable "backend_memory" {
  description = "Memory for the Node.js backend Cloud Run service."
  type        = string
  default     = "512Mi"
}

variable "java_cpu" {
  description = "vCPU for the Java Cloud Run service."
  type        = string
  default     = "1"
}

variable "java_memory" {
  description = "Memory for the Java Cloud Run service. Spring Boot usually needs more RAM."
  type        = string
  default     = "1Gi"
}

variable "frontend_port" {
  description = "Container port for the frontend service."
  type        = number
  default     = 3000
}

variable "backend_port" {
  description = "Container port for the Node.js backend."
  type        = number
  default     = 8080
}

variable "java_port" {
  description = "Container port for the Spring Boot service."
  type        = number
  default     = 8080
}

variable "allow_unauthenticated" {
  description = "If true, Cloud Run services are publicly invokable (typical for a web app)."
  type        = bool
  default     = true
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

variable "labels" {
  description = "Common labels applied to supported resources."
  type        = map(string)
  default     = {}
}
