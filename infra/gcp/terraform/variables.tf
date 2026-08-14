variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Primary Google Cloud region."
  type        = string
  default     = "europe-west2"
}

variable "zone" {
  description = "Primary Google Cloud zone."
  type        = string
  default     = "europe-west2-b"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "github_repository" {
  description = "GitHub repository allowed to deploy."
  type        = string
  default     = "eojgroup/robur"
}

variable "github_branch" {
  description = "GitHub branch allowed to deploy."
  type        = string
  default     = "main"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace for Robur workloads."
  type        = string
  default     = "robur"
}

variable "domain_name" {
  description = "Public web domain, such as app.robur.app."
  type        = string
  default     = ""
}

variable "cloud_sql_tier" {
  description = "Cloud SQL tier for the Robur Postgres instance."
  type        = string
  default     = "db-custom-1-3840"
}

variable "healthkit_ingest_token" {
  description = "Shared token accepted by the API for HealthKit sync during the initial shell phase."
  type        = string
  default     = ""
  sensitive   = true
}
