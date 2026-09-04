terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.40"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

# billing_project + user_project_override: some APIs — billingbudgets among them
# — refuse a call made with plain user credentials unless it names a project to
# bill the quota to. Without this the budget fails with a 403 whose `consumer` is
# projects/764086051850, gcloud's shared default project, rather than this one.
# Setting the ADC quota project is not enough: the provider has to send it.
provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
