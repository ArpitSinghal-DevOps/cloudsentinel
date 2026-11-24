import json

import boto3
import pytest
from moto import mock_aws

import handler

REGION = "eu-north-1"
BUCKET = "some-team-bucket"
OPEN = {
    "BlockPublicAcls": False,
    "IgnorePublicAcls": False,
    "BlockPublicPolicy": False,
    "RestrictPublicBuckets": False,
}


def cloudtrail_event(bucket=BUCKET, name="DeleteBucketPublicAccessBlock"):
    return {
        "source": "aws.s3",
        "detail-type": "AWS API Call via CloudTrail",
        "detail": {
            "eventName": name,
            "eventSource": "s3.amazonaws.com",
            "userIdentity": {"arn": "arn:aws:iam::123456789012:user/someone"},
            "requestParameters": {"bucketName": bucket},
        },
    }


@pytest.fixture
def aws(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})

        # Read what the Lambda publishes through an SQS queue subscribed to the topic.
        sns = boto3.client("sns", region_name=REGION)
        sqs = boto3.client("sqs", region_name=REGION)
        topic = sns.create_topic(Name="cloudsentinel-alerts")["TopicArn"]
        queue = sqs.create_queue(QueueName="inbox")["QueueUrl"]
        queue_arn = sqs.get_queue_attributes(QueueUrl=queue, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        sns.subscribe(TopicArn=topic, Protocol="sqs", Endpoint=queue_arn)
        monkeypatch.setenv("ALERT_TOPIC_ARN", topic)

        def alerts():
            msgs = sqs.receive_message(QueueUrl=queue, MaxNumberOfMessages=10).get("Messages", [])
            return [json.loads(m["Body"]) for m in msgs]

        yield s3, alerts


def make_public(s3):
    s3.put_public_access_block(Bucket=BUCKET, PublicAccessBlockConfiguration=OPEN)
    s3.put_bucket_policy(
        Bucket=BUCKET,
        Policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": "*",
                "Action": "s3:GetObject",
                "Resource": f"arn:aws:s3:::{BUCKET}/*",
            }],
        }),
    )


def block_settings(s3):
    return s3.get_public_access_block(Bucket=BUCKET)["PublicAccessBlockConfiguration"]


def test_public_bucket_is_locked_down(aws):
    s3, alerts = aws
    make_public(s3)

    result = handler.handler(cloudtrail_event(name="PutBucketPolicy"), None)

    assert result["status"] == "remediated"
    assert result["policy_was_public"] is True
    assert block_settings(s3) == handler.FULL_BLOCK
    sent = alerts()
    assert len(sent) == 1
    assert BUCKET in sent[0]["Subject"]
    assert "PutBucketPolicy" in sent[0]["Message"]
    assert "user/someone" in sent[0]["Message"]


def test_policy_is_left_in_place(aws):
    s3, _ = aws
    make_public(s3)

    policy_before = s3.get_bucket_policy(Bucket=BUCKET)["Policy"]

    handler.handler(cloudtrail_event(), None)

    assert s3.get_bucket_policy(Bucket=BUCKET)["Policy"] == policy_before


def test_bucket_without_any_block_config(aws):
    s3, _ = aws
    s3.delete_public_access_block(Bucket=BUCKET)

    result = handler.handler(cloudtrail_event(), None)

    assert result["status"] == "remediated"
    assert result["block_before"] == {k: False for k in handler.FULL_BLOCK}
    assert block_settings(s3) == handler.FULL_BLOCK


def test_already_blocked_is_a_no_op(aws):
    s3, alerts = aws
    s3.put_public_access_block(Bucket=BUCKET, PublicAccessBlockConfiguration=handler.FULL_BLOCK)

    # This is the event our own fix produces; it must not loop or alert.
    result = handler.handler(cloudtrail_event(name="PutBucketPublicAccessBlock"), None)

    assert result["status"] == "compliant"
    assert alerts() == []


def test_one_setting_off_is_enough_to_act(aws):
    s3, _ = aws
    s3.put_public_access_block(
        Bucket=BUCKET,
        PublicAccessBlockConfiguration={**handler.FULL_BLOCK, "RestrictPublicBuckets": False},
    )

    result = handler.handler(cloudtrail_event(name="PutBucketPublicAccessBlock"), None)

    assert result["status"] == "remediated"
    assert block_settings(s3) == handler.FULL_BLOCK


def test_tagged_bucket_is_allowed_to_be_public(aws):
    s3, alerts = aws
    make_public(s3)
    s3.put_bucket_tagging(Bucket=BUCKET, Tagging={"TagSet": [{"Key": handler.ALLOW_TAG, "Value": "true"}]})

    result = handler.handler(cloudtrail_event(), None)

    assert result["status"] == "allowed"
    assert block_settings(s3) == OPEN
    assert alerts() == []


def test_deleted_bucket_is_ignored(aws):
    _, alerts = aws

    result = handler.handler(cloudtrail_event(bucket="already-gone"), None)

    assert result["status"] == "gone"
    assert alerts() == []


def test_event_without_bucket_is_ignored(aws):
    event = cloudtrail_event()
    del event["detail"]["requestParameters"]

    assert handler.handler(event, None)["status"] == "ignored"
