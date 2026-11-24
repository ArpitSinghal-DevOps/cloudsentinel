variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "github_repo" {
  description = "owner/name of the repo whose workflows may assume the CI roles"
  type        = string
  default     = "ArpitSinghal-DevOps/cloudsentinel"
}

# GitHub puts the numeric owner and repo ids in the OIDC subject
# (repo:owner@id/name@id:...). Pinning them means a repo re-created under the same
# name after a delete or rename can't assume these roles.
variable "github_owner_id" {
  type    = number
  default = 144610884
}

variable "github_repo_id" {
  type    = number
  default = 1470357600
}

variable "alert_email" {
  description = "Where budget alerts go. Set it in terraform.tfvars, not here."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 5
}
