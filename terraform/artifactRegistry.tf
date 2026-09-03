resource "google_artifact_registry_repository" "main" {
  location      = var.region
  repository_id = local.artifact_registry_repository_id
  description   = "Docker images for Trustex: frontend, backend, dss and the setup job."
  format        = "DOCKER"
  labels        = local.common_labels

  cleanup_policy_dry_run = false

  # Keep only recent images to limit storage cost.
  cleanup_policies {
    id     = "keep-minimum-versions"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s" # 30 days
    }
  }

  depends_on = [time_sleep.api_propagation]
}
