#!/usr/bin/env bash
# One-time setup for the remote state backend. Terraform can't create the
# bucket it stores its own state in, so this is a plain aws cli script, run
# once by hand before the first `terraform init` in platform/terraform/.
# Locking uses the S3 backend's native lockfile (Terraform >= 1.10), so no
# DynamoDB table is needed. Safe to re-run.
set -euo pipefail

REGION="${REGION:-ap-south-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-stampede-tfstate-$ACCOUNT_ID}"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

cat <<MSG

Remote state backend ready. Run this from platform/terraform/:

  terraform init \\
    -backend-config="bucket=$BUCKET" \\
    -backend-config="key=stampede.tfstate" \\
    -backend-config="region=$REGION"

After the demo, \`terraform destroy\` removes everything except this state
bucket. Delete it last: aws s3 rb s3://$BUCKET --force
MSG
