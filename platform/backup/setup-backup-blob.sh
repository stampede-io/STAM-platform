#!/usr/bin/env bash
# One-time Azure setup for STAM-59: creates the stampede-backups container,
# its 30-day cool-tier lifecycle rule (AC5), and a service principal scoped
# to just that container (least privilege -- not a subscription-wide
# contributor role). Run once by hand, like bootstrap-state.sh. Prints the
# values to put in the azure-backup-credentials Secret.
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-stampede}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?set STORAGE_ACCOUNT to the account terraform created (terraform output -raw storage_account_name)}"
CONTAINER="stampede-backups"

az storage container create \
  --name "$CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --output none

# AC5: cool-tier blobs older than 30 days are deleted automatically.
az storage account management-policy create \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --policy '{
    "rules": [{
      "name": "expire-backups-after-30-days",
      "enabled": true,
      "type": "Lifecycle",
      "definition": {
        "actions": { "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 30 } } },
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["'"$CONTAINER"'/"] }
      }
    }]
  }' \
  --output none

SP_JSON=$(az ad sp create-for-rbac \
  --name "stampede-backup-$(openssl rand -hex 3)" \
  --role "Storage Blob Data Contributor" \
  --scopes "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT/blobServices/default/containers/$CONTAINER")

cat <<EOF

Lifecycle policy applied. Create the Secret the CronJob reads:

  kubectl create secret generic azure-backup-credentials -n apps \\
    --from-literal=client-id=$(echo "$SP_JSON" | grep -o '"appId": *"[^"]*"' | cut -d'"' -f4) \\
    --from-literal=client-secret=$(echo "$SP_JSON" | grep -o '"password": *"[^"]*"' | cut -d'"' -f4) \\
    --from-literal=tenant-id=$(echo "$SP_JSON" | grep -o '"tenant": *"[^"]*"' | cut -d'"' -f4) \\
    --from-literal=storage-account=$STORAGE_ACCOUNT

Save the client-secret now -- az won't show it again.
EOF
