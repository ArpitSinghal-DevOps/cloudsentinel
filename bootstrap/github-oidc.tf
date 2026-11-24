# GitHub Actions gets short-lived AWS credentials through OIDC, so there are no
# access keys stored in GitHub. Two roles:
#   plan  - any pull request in the repo, read-only
#   apply - only workflows running on main
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_sub = "token.actions.githubusercontent.com:sub"
  oidc_aud = "token.actions.githubusercontent.com:aud"

  github_owner = split("/", var.github_repo)[0]
  github_name  = split("/", var.github_repo)[1]
  oidc_subject = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = local.oidc_aud
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = local.oidc_sub
      values   = ["${local.oidc_subject}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = local.oidc_aud
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = local.oidc_sub
      values   = ["${local.oidc_subject}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "cloudsentinel-gha-plan"
  description          = "terraform plan from pull requests (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role" "apply" {
  name                 = "cloudsentinel-gha-apply"
  description          = "terraform apply from main"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# Both roles need to read everything Terraform refreshes.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "apply_readonly" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan may only touch lock files; it never writes state.
data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}
