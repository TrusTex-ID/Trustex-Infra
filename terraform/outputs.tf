output "artifact_registry_url" {
  description = "Base URL for pushing Docker images (append /<image>:<tag>)."
  value       = local.artifact_registry_url
}

output "frontend_url" {
  description = "Cloud Run URL for the Next.js frontend."
  value       = google_cloud_run_v2_service.frontend.uri
}

output "backend_url" {
  description = "Cloud Run URL for the Node.js backend."
  value       = google_cloud_run_v2_service.backend.uri
}

output "java_url" {
  description = "Cloud Run URL for the Spring Boot service."
  value       = google_cloud_run_v2_service.java.uri
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

output "db_password_secret_id" {
  description = "Secret Manager secret ID holding a copy of DB_PASSWORD from terraform/secrets/postgres."
  value       = google_secret_manager_secret.db_password.secret_id
}

output "frontend_service_account" {
  description = "Service account email used by the frontend Cloud Run service."
  value       = google_service_account.frontend.email
}

output "backend_service_account" {
  description = "Service account email used by the backend Cloud Run service."
  value       = google_service_account.backend.email
}

output "java_service_account" {
  description = "Service account email used by the Java Cloud Run service."
  value       = google_service_account.java.email
}

output "frontend_domain_mapping_records" {
  description = "DNS records required when frontend_custom_domain is set."
  value = var.frontend_custom_domain != "" ? [
    for rr in try(google_cloud_run_domain_mapping.frontend[0].status[0].resource_records, []) : {
      type  = rr.type
      name  = rr.name
      rrdata = rr.rrdata
    }
  ] : []
}

output "load_balancer_ip" {
  description = "Global LB IP (only when enable_load_balancer = true)."
  value       = try(google_compute_global_address.lb[0].address, null)
}

output "suggested_image_paths" {
  description = "Suggested Artifact Registry image paths for CI/CD pushes."
  value = {
    frontend = "${local.artifact_registry_url}/frontend"
    backend  = "${local.artifact_registry_url}/backend"
    java     = "${local.artifact_registry_url}/java"
  }
}
