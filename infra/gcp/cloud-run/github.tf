// Reuse Robur's existing OIDC identity, restricted to eojgroup/robur main.
// Its base Terraform permissions are maintained in the bootstrap/legacy state.
// These additions enable this Cloud Run stack without granting billing-account
// access or permission in any other Google project.
locals { github_deployer = "serviceAccount:terraform-github-oidc@robur-505508.iam.gserviceaccount.com" }

resource "google_project_iam_member" "github_cloud_roles" {
  for_each = toset(["roles/run.admin", "roles/monitoring.alertPolicyEditor", "roles/iam.roleAdmin"])
  project  = var.project_id
  role     = each.value
  member   = local.github_deployer
}

resource "google_project_iam_custom_role" "github_budget" {
  project     = var.project_id
  role_id     = "roburHealthBudgetManager"
  title       = "Robur project budget management"
  description = "Read and maintain only budgets scoped to this project."
  permissions = ["resourcemanager.projects.get", "billing.resourcebudgets.read", "billing.resourcebudgets.write"]
}
resource "google_project_iam_member" "github_budget" {
  project = var.project_id
  role    = google_project_iam_custom_role.github_budget.name
  member  = local.github_deployer
}
