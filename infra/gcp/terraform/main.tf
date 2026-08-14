data "google_project" "current" {
  project_id = var.project_id
}

locals {
  app_name        = "robur"
  artifact_repo   = "robur-app"
  cluster_name    = "robur-cluster"
  sql_instance    = "robur-sql"
  github_sa_id    = "terraform-github-oidc"
  workload_pool   = "robur-oidc-pool"
  workload_provider = "gh-provider"
}

resource "google_project_service" "enabled_services" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com"
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "terraform_state" {
  name                        = "robur-tf-state"
  project                     = var.project_id
  location                    = var.region
  force_destroy               = false
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  labels = {
    app         = local.app_name
    environment = var.environment
    purpose     = "terraform-state"
  }

  depends_on = [google_project_service.enabled_services["storage.googleapis.com"]]
}

resource "google_artifact_registry_repository" "robur_app" {
  project       = var.project_id
  repository_id = local.artifact_repo
  location      = var.region
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-old-versions"
    action = "DELETE"

    condition {
      tag_state  = "ANY"
      older_than = "1209600s"
    }
  }

  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }

  labels = {
    app         = local.app_name
    environment = var.environment
    purpose     = "docker-images"
  }

  depends_on = [google_project_service.enabled_services["artifactregistry.googleapis.com"]]
}

resource "google_pubsub_topic" "fitness_events" {
  project = var.project_id
  name    = "robur-fitness-events"

  message_retention_duration = "86400s"

  labels = {
    app    = local.app_name
    domain = "fitness"
  }

  depends_on = [google_project_service.enabled_services["pubsub.googleapis.com"]]
}

resource "google_secret_manager_secret" "healthkit_ingest_token" {
  project   = var.project_id
  secret_id = "robur-healthkit-ingest-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled_services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "healthkit_ingest_token" {
  count       = trimspace(var.healthkit_ingest_token) == "" ? 0 : 1
  secret      = google_secret_manager_secret.healthkit_ingest_token.id
  secret_data = var.healthkit_ingest_token
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = local.workload_pool
  display_name              = "Robur GitHub Actions"

  depends_on = [google_project_service.enabled_services["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.workload_provider
  display_name                       = "GitHub provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "attribute.repository == '${var.github_repository}' && attribute.ref == 'refs/heads/${var.github_branch}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_deploy" {
  project      = var.project_id
  account_id   = local.github_sa_id
  display_name = "Robur GitHub OIDC deployer"
}

resource "google_service_account_iam_binding" "github_deploy_workload_identity_user" {
  service_account_id = google_service_account.github_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
  ]
}

resource "google_project_iam_member" "github_deploy_roles" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/container.developer",
    "roles/iam.serviceAccountUser",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
    "roles/cloudsql.admin",
    "roles/pubsub.admin"
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_deploy.email}"
}

resource "google_container_cluster" "primary" {
  name     = local.cluster_name
  project  = var.project_id
  location = var.region

  initial_node_count       = 1
  remove_default_node_pool = true
  deletion_protection      = true

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.enabled_services["container.googleapis.com"]]
}

resource "google_container_node_pool" "primary" {
  name       = "robur-primary"
  project    = var.project_id
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 1

  node_config {
    machine_type    = "e2-small"
    preemptible     = true
    service_account = google_service_account.github_deploy.email

    labels = {
      app = local.app_name
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

resource "google_service_account" "robur_sql_gsa" {
  project      = var.project_id
  account_id   = "robur-sql-gsa"
  display_name = "Robur Cloud SQL Workload Identity service account"
}

resource "google_project_iam_member" "robur_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.robur_sql_gsa.email}"
}

resource "google_pubsub_topic_iam_member" "api_fitness_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.fitness_events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.robur_sql_gsa.email}"
}

resource "google_service_account_iam_binding" "robur_workload_identity_users" {
  service_account_id = google_service_account.robur_sql_gsa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/api-sa]",
    "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/flyway-sa]"
  ]
}

data "google_compute_network" "vpc" {
  project = var.project_id
  name    = "default"
}

resource "google_compute_global_address" "sql_psa_range" {
  name          = "robur-sql-psa-range"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.vpc.self_link
}

resource "google_service_networking_connection" "vpc_connection" {
  network                 = data.google_compute_network.vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_psa_range.name]

  depends_on = [google_project_service.enabled_services["servicenetworking.googleapis.com"]]
}

resource "random_password" "db_password" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "pg" {
  name                = local.sql_instance
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = true

  settings {
    tier              = var.cloud_sql_tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    activation_policy = "ALWAYS"
    edition           = "ENTERPRISE"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.vpc.self_link
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  depends_on = [
    google_project_service.enabled_services["sqladmin.googleapis.com"],
    google_service_networking_connection.vpc_connection
  ]
}

resource "google_sql_database" "db" {
  name     = "robur"
  project  = var.project_id
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "app" {
  name     = "robur_app"
  project  = var.project_id
  instance = google_sql_database_instance.pg.name
  password = random_password.db_password.result
}
