output "demo_bucket" {
  value = aws_s3_bucket.demo.bucket
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
