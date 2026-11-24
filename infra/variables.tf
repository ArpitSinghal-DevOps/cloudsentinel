variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "alert_email" {
  description = "Subscribed to the alerts topic. Comes from a GitHub secret in CI."
  type        = string
  sensitive   = true
}
