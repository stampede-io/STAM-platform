#!/usr/bin/env bash
# One-time setup for the remote state backend (AC6). Terraform can't create
# the storage account it's about to store its own state in, so this is a
# plain az cli script, run once, by hand, before the first `terraform init`
# in platform/terraform/. Safe to re-run — every step is idempotent.
set -euo pipefail

RG="rg-stampede-tfstate"
LOCATION="${LOCATION:-eastus}"
STORAGE_ACCOUNT="sttfstampede$(openssl rand -hex 3)"
CONTAINER="tfstate"

az group create --name "$RG" --location "$LOCATION" --output none

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --encryption-services blob \
  --allow-blob-public-access false \
  --output none

az storage container create \
  --name "$CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --output none

cat <<EOF

Remote state backend ready. Run this from platform/terraform/:

  terraform init \\
    -backend-config="resource_group_name=$RG" \\
    -backend-config="storage_account_name=$STORAGE_ACCOUNT" \\
    -backend-config="container_name=$CONTAINER" \\
    -backend-config="key=stampede.tfstate"

Save these three values (storage account name especially — it's random) —
every teammate running terraform needs the same -backend-config args.
EOF
