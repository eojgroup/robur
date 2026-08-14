variable "project_id" {
  description = "Google Cloud project ID that owns the static web mock-up."
  type        = string
}

variable "region" {
  description = "Google Cloud region for project-scoped operations. Firebase Hosting itself is global/CDN-backed."
  type        = string
  default     = "europe-west2"
}

variable "hosting_site_id" {
  description = "Globally unique Firebase Hosting site ID. This is normally the project ID for the default site."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,28}[a-z0-9])?$", var.hosting_site_id))
    error_message = "hosting_site_id must be a lowercase DNS-label-style Firebase Hosting site ID."
  }
}

variable "domain_name" {
  description = "Optional custom domain to attach after DNS records are added, such as robur.fit."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be blank or a lowercase fully qualified domain name without a protocol."
  }
}

variable "github_repository" {
  description = "GitHub repository permitted to exchange OIDC tokens for web deployment."
  type        = string
  default     = "eojgroup/robur"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repository form."
  }
}

variable "github_branch" {
  description = "Only this branch can obtain the deployment identity."
  type        = string
  default     = "main"
}

variable "billing_account_id" {
  description = "Optional billing account ID for a project-scoped budget alert. Leave blank when billing IAM is unavailable."
  type        = string
  default     = ""
}

variable "budget_currency" {
  description = "ISO 4217 currency code for the optional budget alert."
  type        = string
  default     = "SEK"
}

variable "monthly_budget_units" {
  description = "Whole currency units at which the optional monthly budget sends alerts. This is an alert, not a spend cap."
  type        = number
  default     = 100

  validation {
    condition     = var.monthly_budget_units > 0
    error_message = "monthly_budget_units must be greater than zero."
  }
}
