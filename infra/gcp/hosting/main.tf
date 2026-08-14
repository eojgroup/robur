data "google_project" "current" {
  project_id = var.project_id
}

locals {
  deploy_sa_id      = "robur-hosting-github"
  workload_pool_id  = "robur-hosting-oidc"
  workload_provider = "github"
}

resource "google_project_service" "enabled_services" {
  for_each = toset(concat([
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com"
  ], var.billing_account_id == "" ? [] : ["billingbudgets.googleapis.com"]))

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Adding Firebase to a GCP project is irreversible, so removal only abandons Terraform state.
resource "google_firebase_project" "robur" {
  provider = google-beta
  project  = var.project_id

  depends_on = [google_project_service.enabled_services["firebase.googleapis.com"]]

  lifecycle {
    # Firebase cannot be removed from a GCP project. Make accidental destroy fail loudly.
    prevent_destroy = true
  }
}

resource "google_firebase_hosting_site" "web" {
  provider        = google-beta
  project         = var.project_id
  site_id         = var.hosting_site_id
  deletion_policy = "ABANDON"

  depends_on = [
    google_firebase_project.robur,
    google_project_service.enabled_services["firebasehosting.googleapis.com"]
  ]
}

# This intentionally does not wait for DNS. Terraform can finish and produce the exact records
# that the registrar must receive; Hosting continues verification once those records propagate.
resource "google_firebase_hosting_custom_domain" "web" {
  provider              = google-beta
  count                 = var.domain_name == "" ? 0 : 1
  project               = var.project_id
  site_id               = google_firebase_hosting_site.web.site_id
  custom_domain         = var.domain_name
  cert_preference       = "GROUPED"
  wait_dns_verification = false
  deletion_policy       = "ABANDON"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = local.workload_pool_id
  display_name              = "Robur static web deployment"
  description               = "GitHub Actions OIDC identities allowed to publish static Hosting releases."

  depends_on = [google_project_service.enabled_services["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.workload_provider
  display_name                       = "GitHub Actions for Robur Hosting"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Restrict both the repository and the exact protected branch before IAM is evaluated.
  attribute_condition = "attribute.repository == '${var.github_repository}' && attribute.ref == 'refs/heads/${var.github_branch}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_deploy" {
  project      = var.project_id
  account_id   = local.deploy_sa_id
  display_name = "Robur static web deployer"
  description  = "Can publish only Firebase Hosting releases through GitHub OIDC."
}

resource "google_service_account_iam_member" "github_deploy_workload_identity_user" {
  service_account_id = google_service_account.github_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# Firebase CLI requires Hosting administration plus consumer access for the quota project.
# It deliberately has no GKE, Cloud SQL, Artifact Registry, Storage-admin, or project-admin roles.
resource "google_project_iam_member" "github_deploy_roles" {
  for_each = toset([
    "roles/firebasehosting.admin",
    "roles/serviceusage.apiKeysViewer",
    "roles/serviceusage.serviceUsageConsumer"
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_deploy.email}"
}

# Budgets do not cap spend. They alert project owners at 50%, 80%, 100%, and forecasted 100%.
# The resource is opt-in because billing-account IAM is intentionally separate from project Owner.
resource "google_billing_budget" "static_web" {
  count           = var.billing_account_id == "" ? 0 : 1
  billing_account = var.billing_account_id
  display_name    = "Robur static web monthly guardrail"
  deletion_policy = "ABANDON"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.monthly_budget_units)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.8
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = []
    enable_project_level_recipients  = true
  }

  depends_on = [google_project_service.enabled_services["billingbudgets.googleapis.com"]]
}
