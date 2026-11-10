output "service_url" { value = google_cloud_run_v2_service.health.uri }
output "service_name" { value = google_cloud_run_v2_service.health.name }
output "region" { value = var.region }
output "database_instance" { value = google_sql_database_instance.health.name }
output "migration_job" { value = google_cloud_run_v2_job.migrate.name }
output "runtime_service_account" { value = google_service_account.runtime.email }
output "build_service_account" { value = google_service_account.build.email }
output "build_source_bucket" { value = google_storage_bucket.build_source.name }
