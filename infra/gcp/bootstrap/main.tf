resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "terraform_state" {
  name                        = var.state_bucket_name
  project                     = var.project_id
  location                    = var.region
  force_destroy               = false
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep recent state history for recovery, but do not retain old versions indefinitely.
  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      days_since_noncurrent_time = 90
      with_state                 = "ARCHIVED"
    }
  }

  labels = {
    app     = "robur"
    purpose = "terraform-state"
  }

  depends_on = [google_project_service.storage]
}
