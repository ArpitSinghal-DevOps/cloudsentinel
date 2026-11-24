# Someone loosens S3 public access -> CloudTrail -> EventBridge -> Lambda turns
# Block Public Access back on -> SNS email.

locals {
  remediate_name = "cloudsentinel-remediate-s3"
}

# Every role the pipeline creates has to carry this boundary (see bootstrap/ci-permissions.tf).
data "aws_iam_policy" "workload_boundary" {
  name = "cloudsentinel-workload-boundary"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "remediate" {
  name                 = local.remediate_name
  path                 = "/cloudsentinel/"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = data.aws_iam_policy.workload_boundary.arn
}

data "aws_iam_policy_document" "remediate" {
  # checkov:skip=CKV_AWS_111:Has to work on any bucket in the account; the only write is turning Block Public Access on
  # checkov:skip=CKV_AWS_109:Same; PutBucketPublicAccessBlock is used only to close a bucket
  statement {
    sid = "InspectAndCloseBuckets"
    actions = [
      "s3:GetBucketTagging",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketPolicyStatus",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["arn:aws:s3:::*"]
  }

  statement {
    sid       = "Alert"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.remediate.arn}:*"]
  }
}

resource "aws_iam_role_policy" "remediate" {
  name   = "remediate-s3"
  role   = aws_iam_role.remediate.id
  policy = data.aws_iam_policy_document.remediate.json
}

resource "aws_cloudwatch_log_group" "remediate" {
  # checkov:skip=CKV_AWS_338:30 days is enough for a demo account and keeps it free
  # checkov:skip=CKV_AWS_158:Default log group encryption; a KMS key would cost $1/month
  name              = "/aws/lambda/${local.remediate_name}"
  retention_in_days = 30
}

data "archive_file" "remediate" {
  type        = "zip"
  source_file = "${path.module}/lambda/remediate_s3/handler.py"
  output_path = "${path.module}/.build/remediate_s3.zip"
}

resource "aws_lambda_function" "remediate" {
  # checkov:skip=CKV_AWS_115:New accounts have 10 concurrent executions and AWS keeps 10 unreserved, so nothing can be reserved
  # checkov:skip=CKV_AWS_116:EventBridge retries failed invocations (retry_policy on the target)
  # checkov:skip=CKV_AWS_117:Only calls AWS APIs; a VPC would need NAT or endpoints, which cost money
  # checkov:skip=CKV_AWS_173:The only env var is the topic ARN, not a secret
  # checkov:skip=CKV_AWS_272:Code signing is out of scope; the code is deployed only by CI from main
  # checkov:skip=CKV_AWS_50:No X-Ray; the boundary does not allow it and logs are enough here
  function_name    = local.remediate_name
  description      = "Turns S3 Block Public Access back on when someone loosens it"
  role             = aws_iam_role.remediate.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.remediate.output_path
  source_code_hash = data.archive_file.remediate.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.remediate, aws_iam_role_policy.remediate]
}

# CloudTrail logs the S3 API name for these calls; both spellings of the
# public-access-block calls are listed because the console and the API differ.
resource "aws_cloudwatch_event_rule" "s3_public_access" {
  name        = "cloudsentinel-s3-public-access"
  description = "S3 bucket ACL, policy or Block Public Access changes"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName = [
        "PutBucketAcl",
        "PutBucketPolicy",
        "PutBucketPublicAccessBlock",
        "DeleteBucketPublicAccessBlock",
        "PutPublicAccessBlock",
        "DeletePublicAccessBlock",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "remediate" {
  rule = aws_cloudwatch_event_rule.s3_public_access.name
  arn  = aws_lambda_function.remediate.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 4
  }
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_public_access.arn
}
