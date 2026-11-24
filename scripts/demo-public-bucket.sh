#!/usr/bin/env bash
# Opens up the demo bucket the way someone might by hand, then watches CloudSentinel
# close it again. Needs AWS CLI credentials that are allowed to change the bucket.
#   scripts/demo-public-bucket.sh
set -euo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo eu-north-1)
BUCKET="cloudsentinel-demo-$ACCOUNT"
URL="https://$BUCKET.s3.$REGION.amazonaws.com/hello.txt"

blocks() {
  aws s3api get-public-access-block --bucket "$BUCKET" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null | tr '\t' ' ' || echo "none"
}
http() { curl -s -o /dev/null -w '%{http_code}' "$URL"; }

echo "hello, this file should not be public" | aws s3 cp - "s3://$BUCKET/hello.txt" >/dev/null
echo "$(date +%T)  start: block public access = $(blocks), anonymous GET = $(http)"

start=$(date +%s)
aws s3api delete-public-access-block --bucket "$BUCKET"
echo "$(date +%T)  removed Block Public Access"

# Usually CloudSentinel has already put the blocks back by now, and S3 refuses the policy.
if aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": \"*\", \"Action\": \"s3:GetObject\",
                     \"Resource\": \"arn:aws:s3:::$BUCKET/*\"}]}" 2>/dev/null; then
  echo "$(date +%T)  public-read policy added, anonymous GET = $(http)"
else
  echo "$(date +%T)  public-read policy refused: Block Public Access is already back on"
fi

until [ "$(blocks)" = "True True True True" ]; do
  sleep 2
  if (( $(date +%s) - start > 300 )); then echo "not fixed after 5 minutes, check the Lambda logs"; exit 1; fi
done
echo "$(date +%T)  Block Public Access back on after $(( $(date +%s) - start ))s, anonymous GET = $(http)"

# leave the bucket as it was
aws s3api delete-bucket-policy --bucket "$BUCKET" 2>/dev/null || true
