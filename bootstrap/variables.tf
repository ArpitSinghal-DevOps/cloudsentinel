variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "github_repo" {
  description = "owner/name of the repo whose workflows may assume the CI roles"
  type        = string
  default     = "ArpitSinghal-DevOps/cloudsentinel"
}

variable "alert_email" {
  description = "Where budget alerts go. Set it in terraform.tfvars, not here."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 5
}
