variable "project_id" {
  description = "Google Cloud project ID that owns the Terraform state bucket."
  type        = string
}

variable "region" {
  description = "Region for the Terraform state bucket."
  type        = string
  default     = "europe-west2"
}

variable "state_bucket_name" {
  description = "Globally unique Cloud Storage bucket name for Terraform state."
  type        = string
}
