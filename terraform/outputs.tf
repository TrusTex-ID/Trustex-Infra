output "artifact_registry_url" {
  description = "Base URL for pushing Docker images (append /<image>:<tag>)."
  value       = local.artifact_registry_url
}

output "frontend_url" {
  description = "Cloud Run URL for the React/Vite SPA. This is the app entry point."
  value       = google_cloud_run_v2_service.frontend.uri
}

output "backend_url" {
  description = "Cloud Run URL for the Express backend. The SPA reaches it through the frontend's /api/v1 proxy, not directly."
  value       = google_cloud_run_v2_service.backend.uri
}

output "dss_url" {
  description = "Cloud Run URL for the EU DSS validation webapp (injected into the backend as DSS_VALIDATION_URL)."
  value       = google_cloud_run_v2_service.dss.uri
}

output "setup_job_name" {
  description = "Cloud Run Job that applies Prisma migrations. Execute it with `make db-setup`."
  value       = google_cloud_run_v2_job.setup.name
}

output "setup_job_execute_command" {
  description = "Ready-to-run command for the database setup job."
  value       = "gcloud run jobs execute ${google_cloud_run_v2_job.setup.name} --region ${var.region} --project ${var.project_id} --wait"
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance)."
  value       = google_sql_database_instance.main.connection_name
}

output "cloud_sql_public_ip" {
  description = "Cloud SQL public IP (apps should use the Cloud SQL connector, not this IP directly)."
  value       = google_sql_database_instance.main.public_ip_address
}

output "db_name" {
  description = "Application database name."
  value       = google_sql_database.app.name
}

output "db_user" {
  description = "Application database user."
  value       = google_sql_user.app.name
}

output "database_url" {
  description = "DATABASE_URL injected into the backend and the setup job (Cloud SQL Unix socket)."
  value       = local.database_url
  sensitive   = true
}

output "frontend_service_account" {
  description = "Service account email used by the frontend Cloud Run service."
  value       = google_service_account.frontend.email
}

output "backend_service_account" {
  description = "Service account email used by the backend Cloud Run service."
  value       = google_service_account.backend.email
}

output "dss_service_account" {
  description = "Service account email used by the DSS Cloud Run service."
  value       = google_service_account.dss.email
}

output "setup_service_account" {
  description = "Service account email used by the database setup Cloud Run Job."
  value       = google_service_account.setup.email
}

output "frontend_domain_mapping_records" {
  description = "DNS records required when frontend_custom_domain is set."
  value = var.frontend_custom_domain != "" ? [
    for rr in try(google_cloud_run_domain_mapping.frontend[0].status[0].resource_records, []) : {
      type   = rr.type
      name   = rr.name
      rrdata = rr.rrdata
    }
  ] : []
}

output "load_balancer_ip" {
  description = "Global LB IP (only when enable_load_balancer = true)."
  value       = try(google_compute_global_address.lb[0].address, null)
}

output "suggested_image_paths" {
  description = "Artifact Registry image paths, one per Dockerfile in the source repos."
  value = {
    frontend = "${local.artifact_registry_url}/frontend"
    backend  = "${local.artifact_registry_url}/backend"
    dss      = "${local.artifact_registry_url}/dss"
    setup    = "${local.artifact_registry_url}/setup"
  }
}

output "project_id" {
  description = "Echoes var.project_id so the Makefile and CI have a single source of truth for it."
  value       = var.project_id
}
