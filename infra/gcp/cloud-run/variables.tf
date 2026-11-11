variable "project_id" {
  type = string
  validation {
    condition     = var.project_id == "robur-505508"
    error_message = "Robur resources must be deployed only to robur-505508."
  }
}
variable "region" {
  type    = string
  default = "europe-west2"
}
variable "container_image" {
  description = "Immutable combined web/API image digest or commit tag."
  type        = string
}
variable "google_web_client_id" {
  description = "Google Auth Platform Web client ID. Empty keeps health sign-in fail closed."
  type        = string
  default     = ""
}
variable "billing_account_id" {
  description = "Billing account ID used only to create the project-filtered budget."
  type        = string
}
variable "monthly_budget_usd" {
  type    = number
  default = 25
  validation {
    condition     = var.monthly_budget_usd > 0 && var.monthly_budget_usd <= 25
    error_message = "This beta deployment must stay within the approved $25 monthly planning budget."
  }
}
variable "billing_currency" {
  description = "Must match the billing account. SEK uses an intentionally early alert of 8 SEK per USD of planning allowance."
  type        = string
  default     = "USD"
  validation {
    condition     = contains(["USD", "SEK"], var.billing_currency)
    error_message = "Review the alert conversion before using a different billing currency."
  }
}
variable "enable_public_service" {
  description = "Enable web access after schema migrations and runtime-role hardening."
  type        = bool
  default     = false
}
