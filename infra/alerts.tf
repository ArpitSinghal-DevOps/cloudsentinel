# Remediation results are published here; the subscription needs a one-time
# confirmation click in the email AWS sends.
resource "aws_sns_topic" "alerts" {
  # checkov:skip=CKV_AWS_26:Messages only contain bucket names and event times. Encrypting with the
  #   AWS managed key would also need KMS rights for the Lambda, which the workload boundary does not give.
  name = "cloudsentinel-alerts"
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "OwnerOnly"
    actions   = ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
