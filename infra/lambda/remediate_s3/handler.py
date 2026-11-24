"""Turns S3 Block Public Access back on when someone loosens it.

Triggered by EventBridge for bucket ACL / policy / public-access-block changes
(see infra/remediation.tf). The bucket policy and ACL are left as they are:
with all four block settings on they no longer grant public access, and
nothing someone wrote into the policy gets lost.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# Buckets that are meant to be public carry this tag with the value "true".
ALLOW_TAG = "cloudsentinel:allow-public"

FULL_BLOCK = {
    "BlockPublicAcls": True,
    "IgnorePublicAcls": True,
    "BlockPublicPolicy": True,
    "RestrictPublicBuckets": True,
}


def handler(event, context):
    detail = event.get("detail") or {}
    bucket = (detail.get("requestParameters") or {}).get("bucketName")
    if not bucket:
        log.info("no bucket in event, ignoring: %s", detail.get("eventName"))
        return {"status": "ignored"}

    s3 = boto3.client("s3")
    who = (detail.get("userIdentity") or {}).get("arn", "unknown")
    what = detail.get("eventName", "unknown")

    try:
        if _allowed_public(s3, bucket):
            log.info("%s is tagged %s=true, leaving it alone", bucket, ALLOW_TAG)
            return {"status": "allowed", "bucket": bucket}

        before = _current_block(s3, bucket)
        if before == FULL_BLOCK:
            # Already locked down. This is also how our own PutPublicAccessBlock
            # call comes back through EventBridge, so it must be a no-op.
            return {"status": "compliant", "bucket": bucket}

        was_public = _policy_is_public(s3, bucket)
        s3.put_public_access_block(Bucket=bucket, PublicAccessBlockConfiguration=FULL_BLOCK)
    except ClientError as err:
        code = err.response["Error"]["Code"]
        if code == "NoSuchBucket":
            log.info("%s no longer exists", bucket)
            return {"status": "gone", "bucket": bucket}
        raise

    result = {
        "status": "remediated",
        "bucket": bucket,
        "trigger": what,
        "actor": who,
        "block_before": before,
        "policy_was_public": was_public,
    }
    log.info(json.dumps(result))
    _notify(result)
    return result


def _allowed_public(s3, bucket):
    try:
        tags = s3.get_bucket_tagging(Bucket=bucket)["TagSet"]
    except ClientError as err:
        if err.response["Error"]["Code"] == "NoSuchTagSet":
            return False
        raise
    return any(t["Key"] == ALLOW_TAG and t["Value"].lower() == "true" for t in tags)


def _current_block(s3, bucket):
    try:
        cfg = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    except ClientError as err:
        if err.response["Error"]["Code"] == "NoSuchPublicAccessBlockConfiguration":
            return {key: False for key in FULL_BLOCK}
        raise
    return {key: bool(cfg.get(key)) for key in FULL_BLOCK}


def _policy_is_public(s3, bucket):
    try:
        return s3.get_bucket_policy_status(Bucket=bucket)["PolicyStatus"]["IsPublic"]
    except ClientError as err:
        if err.response["Error"]["Code"] == "NoSuchBucketPolicy":
            return False
        raise


def _notify(result):
    loosened = [key for key, on in result["block_before"].items() if not on]
    lines = [
        f"Bucket {result['bucket']} was opened up and has been locked down again.",
        "",
        f"Change:      {result['trigger']}",
        f"Made by:     {result['actor']}",
        f"Was off:     {', '.join(loosened)}",
        f"Policy was public: {'yes' if result['policy_was_public'] else 'no'}",
        "",
        "All four Block Public Access settings are back on. The bucket policy and ACL were not touched.",
        f"If this bucket really should be public, tag it {ALLOW_TAG}=true.",
    ]
    boto3.client("sns").publish(
        TopicArn=os.environ["ALERT_TOPIC_ARN"],
        Subject=f"[CloudSentinel] public access removed from {result['bucket']}"[:100],
        Message="\n".join(lines),
    )
