locals {
  service_name = "robur-health"
  database     = "robur"
  runtime_user = "robur_app"
}

data "google_project" "current" { project_id = var.project_id }

resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com", "billingbudgets.googleapis.com",
    "cloudbuild.googleapis.com", "iam.googleapis.com", "logging.googleapis.com",
    "monitoring.googleapis.com", "run.googleapis.com", "secretmanager.googleapis.com",
    "sqladmin.googleapis.com", "storage.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_sql_database_instance" "health" {
  name                = "robur-health-sql"
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_17"
  deletion_protection = true
  settings {
    edition                     = "ENTERPRISE"
    tier                        = "db-f1-micro"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = false
    deletion_protection_enabled = true
    ip_configuration {
      ipv4_enabled = true
      # No authorized networks. Connections require Cloud SQL Auth Proxy IAM/TLS.
      ssl_mode = "ENCRYPTED_ONLY"
    }
    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      location                       = var.region
      point_in_time_recovery_enabled = false
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }
    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
    user_labels = { app = "robur", cost_profile = "beta-25-usd" }
  }
  depends_on = [google_project_service.required["sqladmin.googleapis.com"]]
}

resource "google_sql_database" "health" {
  name     = local.database
  project  = var.project_id
  instance = google_sql_database_instance.health.name
}

resource "random_password" "runtime" {
  length  = 40
  special = false
}
resource "random_password" "migrations" {
  length  = 40
  special = false
}
resource "google_sql_user" "runtime" {
  name     = local.runtime_user
  project  = var.project_id
  instance = google_sql_database_instance.health.name
  password = random_password.runtime.result
  # migrate.js removes Cloud SQL's implicit administrator role before web access.
}
resource "google_sql_user" "migrations" {
  name     = "postgres"
  project  = var.project_id
  instance = google_sql_database_instance.health.name
  password = random_password.migrations.result
}

resource "google_secret_manager_secret" "database_urls" {
  for_each  = toset(["runtime", "migrations"])
  project   = var.project_id
  secret_id = "robur-health-db-${each.key}"
  replication {
    user_managed {
      replicas { location = var.region }
    }
  }
  depends_on = [google_project_service.required["secretmanager.googleapis.com"]]
}
resource "google_secret_manager_secret_version" "runtime" {
  secret      = google_secret_manager_secret.database_urls["runtime"].id
  secret_data = "postgresql://${local.runtime_user}:${random_password.runtime.result}@localhost/${local.database}?host=${urlencode("/cloudsql/${google_sql_database_instance.health.connection_name}")}"
}
resource "google_secret_manager_secret_version" "migrations" {
  secret      = google_secret_manager_secret.database_urls["migrations"].id
  secret_data = "postgresql://postgres:${random_password.migrations.result}@localhost/${local.database}?host=${urlencode("/cloudsql/${google_sql_database_instance.health.connection_name}")}"
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "robur-health-runtime"
  display_name = "Robur web and API runtime"
}
resource "google_service_account" "migrations" {
  project      = var.project_id
  account_id   = "robur-health-migrations"
  display_name = "Robur schema migrations only"
}
resource "google_project_iam_member" "sql_client" {
  for_each = { runtime = google_service_account.runtime.email, migrations = google_service_account.migrations.email }
  project  = var.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${each.value}"
}

resource "google_storage_bucket" "build_source" {
  name                        = "${var.project_id}-robur-build-source"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  lifecycle_rule {
    condition { age = 1 }
    action { type = "Delete" }
  }
  depends_on = [google_project_service.required["storage.googleapis.com"]]
}
resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "robur-health-build"
  display_name = "Robur container build only"
}
resource "google_storage_bucket_iam_member" "build_source" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.build.email}"
}
resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}
resource "google_artifact_registry_repository_iam_member" "build_images" {
  project    = var.project_id
  location   = var.region
  repository = "robur-app"
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}
resource "google_secret_manager_secret_iam_member" "database_urls" {
  for_each  = { runtime = google_service_account.runtime.email, migrations = google_service_account.migrations.email }
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_urls[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value}"
}

resource "google_cloud_run_v2_service" "health" {
  name                = local.service_name
  project             = var.project_id
  location            = var.region
  deletion_protection = true
  ingress             = "INGRESS_TRAFFIC_ALL"
  template {
    service_account                  = google_service_account.runtime.email
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    containers {
      image = var.container_image
      ports { container_port = 8080 }
      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = false
      }
      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "GOOGLE_WEB_CLIENT_ID"
        value = var.google_web_client_id
      }
      env {
        name  = "DATABASE_POOL_MAX"
        value = "5"
      }
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_urls["runtime"].secret_id
            version = google_secret_manager_secret_version.runtime.version
          }
        }
      }
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
      startup_probe {
        initial_delay_seconds = 0
        period_seconds        = 5
        failure_threshold     = 20
        http_get {
          path = "/healthz"
          port = 8080
        }
      }
      liveness_probe {
        period_seconds = 30
        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance { instances = [google_sql_database_instance.health.connection_name] }
    }
  }
  depends_on = [google_project_service.required["run.googleapis.com"], google_project_iam_member.sql_client,
  google_secret_manager_secret_iam_member.database_urls]
}
resource "google_cloud_run_v2_service_iam_member" "web_access" {
  count    = var.enable_public_service ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.health.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_job" "migrate" {
  name                = "robur-health-migrate"
  project             = var.project_id
  location            = var.region
  deletion_protection = true
  template {
    template {
      service_account = google_service_account.migrations.email
      max_retries     = 0
      timeout         = "300s"
      containers {
        image   = var.container_image
        command = ["node", "apps/api/dist/migrate.js"]
        resources {
          limits = { cpu = "1", memory = "512Mi" }
        }
        env {
          name  = "APP_DATABASE_ROLE"
          value = local.runtime_user
        }
        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.database_urls["migrations"].secret_id
              version = google_secret_manager_secret_version.migrations.version
            }
          }
        }
        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
      volumes {
        name = "cloudsql"
        cloud_sql_instance { instances = [google_sql_database_instance.health.connection_name] }
      }
    }
  }
  depends_on = [google_project_service.required["run.googleapis.com"], google_project_iam_member.sql_client,
  google_secret_manager_secret_iam_member.database_urls]
}

resource "google_billing_budget" "robur" {
  billing_account = var.billing_account_id
  display_name    = "Robur beta USD ${var.monthly_budget_usd} planning ceiling"
  budget_filter { projects = ["projects/${data.google_project.current.number}"] }
  amount {
    specified_amount {
      currency_code = var.billing_currency
      units         = tostring(floor(var.monthly_budget_usd * (var.billing_currency == "SEK" ? 8 : 1)))
    }
  }
  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content { threshold_percent = threshold_rules.value }
  }
  depends_on = [google_project_service.required["billingbudgets.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "database_disk" {
  project      = var.project_id
  display_name = "Robur PostgreSQL disk above 80 percent"
  combiner     = "OR"
  conditions {
    display_name = "Fixed 10GB disk capacity"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${var.project_id}:${google_sql_database_instance.health.name}\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger { count = 1 }
    }
  }
  depends_on = [google_project_service.required["monitoring.googleapis.com"]]
}
