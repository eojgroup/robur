output "project_id" {
  value = var.project_id
}

output "gke_cluster_name" {
  value = google_container_cluster.primary.name
}

output "artifact_registry_repository" {
  value = google_artifact_registry_repository.robur_app.name
}

output "artifact_registry_location" {
  value = var.region
}

output "workload_identity_provider" {
  value = "${google_iam_workload_identity_pool.github.name}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "github_deploy_service_account" {
  value = google_service_account.github_deploy.email
}

output "instance_connection_name" {
  value = google_sql_database_instance.pg.connection_name
}

output "private_ip_address" {
  value = google_sql_database_instance.pg.private_ip_address
}

output "db_name" {
  value = google_sql_database.db.name
}

output "db_user" {
  value = google_sql_user.app.name
}

output "db_pass" {
  value     = random_password.db_password.result
  sensitive = true
}

output "robur_api_gsa_email" {
  value = google_service_account.robur_api.email
}

output "robur_migrations_gsa_email" {
  value = google_service_account.robur_migrations.email
}

output "gke_node_gsa_email" {
  value = google_service_account.gke_nodes.email
}

output "fitness_events_topic" {
  value = google_pubsub_topic.fitness_events.name
}
