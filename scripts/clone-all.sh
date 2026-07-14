#!/bin/bash
set -e
ORG="stampede-io"
REPOS=(STAM-gateway STAM-identity STAM-catalog STAM-booking STAM-payment STAM-notification STAM-frontend STAM-platform STAM-gitops)
for repo in "${REPOS[@]}"; do
  if [ ! -d "$repo" ]; then
    git clone "https://github.com/$ORG/$repo.git"
  else
    echo "$repo already exists, skipping"
  fi
done
echo "All repos cloned. Run: cd STAM-platform/compose-dev && docker compose up"
