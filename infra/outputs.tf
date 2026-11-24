output "demo_bucket" {
  value = aws_s3_bucket.demo.bucket
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "remediation_function" {
  value = aws_lambda_function.remediate.function_name
}

output "trail_name" {
  value = aws_cloudtrail.main.name
}
