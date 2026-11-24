output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "workload_boundary_arn" {
  description = "Every IAM role created by the main stack must use this boundary"
  value       = aws_iam_policy.workload_boundary.arn
}
