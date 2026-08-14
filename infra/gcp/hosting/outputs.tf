output "hosting_site_id" {
  description = "Firebase Hosting site receiving the static web build."
  value       = google_firebase_hosting_site.web.site_id
}

output "default_url" {
  description = "Cost-free Firebase Hosting URL available before custom-domain DNS is verified."
  value       = google_firebase_hosting_site.web.default_url
}

output "workload_identity_provider" {
  description = "Fully qualified provider resource for the GitHub Actions auth action."
  value       = "${google_iam_workload_identity_pool.github.name}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "github_deploy_service_account" {
  description = "Service account impersonated by GitHub Actions through OIDC."
  value       = google_service_account.github_deploy.email
}

output "custom_domain_dns_updates" {
  description = "DNS records required by Firebase Hosting. Apply them at the robur.fit registrar."
  value       = try(google_firebase_hosting_custom_domain.web[0].required_dns_updates, [])
}

output "custom_domain_host_state" {
  description = "Firebase Hosting custom-domain status."
  value       = try(google_firebase_hosting_custom_domain.web[0].host_state, "NOT_CONFIGURED")
}

output "custom_domain_ownership_state" {
  description = "DNS ownership-verification status for the custom domain."
  value       = try(google_firebase_hosting_custom_domain.web[0].ownership_state, "NOT_CONFIGURED")
}
