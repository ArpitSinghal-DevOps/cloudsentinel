data "aws_caller_identity" "current" {}

# A normal, private bucket. In the remediation demo it gets made public by hand in
# the console, and CloudSentinel has to put it back.
resource "aws_s3_bucket" "demo" {
  # checkov:skip=CKV_AWS_18:Demo bucket, no access logs needed
  # checkov:skip=CKV2_AWS_62:No event notifications needed; changes are picked up from CloudTrail
  # checkov:skip=CKV_AWS_144:Single-region project
  # checkov:skip=CKV_AWS_145:SSE-S3 is enough here and a KMS key would cost $1/month
  bucket = "cloudsentinel-demo-${data.aws_caller_identity.current.account_id}"

  # holds nothing important, so terraform destroy may empty it
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
