# Write access for the apply role, scoped by name to this project's resources.
#
# IAM is the tricky part: a role that can create roles and attach policies can make
# itself admin. So workload roles must live under the /cloudsentinel/ path and must
# carry the boundary below, which caps what any of them can ever do (no IAM at all).

locals {
  arn_prefix = "arn:aws:%s:${var.region}:${local.account_id}"
}

data "aws_iam_policy_document" "workload_boundary" {
  # checkov:skip=CKV_AWS_109:Remediation has to be able to lock down any bucket in the account
  # checkov:skip=CKV_AWS_111:Same as above; the actions only ever make a bucket less public
  #
  # The remediation Lambda must be able to close any bucket in the account, so these
  # are on every bucket. They are bucket settings only: no object read or write.
  statement {
    sid = "LockDownBuckets"
    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketAcl",
      "s3:PutBucketAcl",
      "s3:GetBucketTagging",
    ]
    resources = ["arn:aws:s3:::*"]
  }

  statement {
    sid       = "Alerts"
    actions   = ["sns:Publish"]
    resources = ["${format(local.arn_prefix, "sns")}:cloudsentinel-*"]
  }

  statement {
    sid     = "OwnLogs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${format(local.arn_prefix, "logs")}:log-group:/aws/lambda/cloudsentinel-*",
      "${format(local.arn_prefix, "logs")}:log-group:/aws/lambda/cloudsentinel-*:*",
    ]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "cloudsentinel-workload-boundary"
  description = "Permissions boundary for every role the CI pipeline creates"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "ProjectBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::cloudsentinel-*", "arn:aws:s3:::cloudsentinel-*/*"]
  }

  # The state bucket also matches cloudsentinel-*; CI must not be able to break it.
  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "CloudTrail"
    actions   = ["cloudtrail:*"]
    resources = ["${format(local.arn_prefix, "cloudtrail")}:trail/cloudsentinel-*"]
  }

  statement {
    sid       = "EventBridge"
    actions   = ["events:*"]
    resources = ["${format(local.arn_prefix, "events")}:rule/cloudsentinel-*"]
  }

  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["${format(local.arn_prefix, "lambda")}:function:cloudsentinel-*"]
  }

  statement {
    sid       = "SNS"
    actions   = ["sns:*"]
    resources = ["${format(local.arn_prefix, "sns")}:cloudsentinel-*"]
  }

  statement {
    sid     = "LambdaLogs"
    actions = ["logs:*"]
    resources = [
      "${format(local.arn_prefix, "logs")}:log-group:/aws/lambda/cloudsentinel-*",
      "${format(local.arn_prefix, "logs")}:log-group:/aws/lambda/cloudsentinel-*:*",
    ]
  }

  statement {
    sid       = "CreateBoundedRoles"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/cloudsentinel/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "ManageWorkloadRoles"
    actions = [
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/cloudsentinel/*"]
  }

  statement {
    sid       = "PassWorkloadRolesToLambda"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/cloudsentinel/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid       = "KeepBoundaries"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "apply" {
  name        = "cloudsentinel-gha-apply"
  description = "Write access for terraform apply, limited to cloudsentinel-* resources"
  policy      = data.aws_iam_policy_document.apply.json
}

resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply.arn
}
