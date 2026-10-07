#!/usr/bin/env bash
# AC5 / CI check: a plain `kind: Secret` is only allowed in the explicitly
# documented kind-local directories below — every one of them already has
# its own "not production-safe, SealedSecrets lands later" comment
# (STAM-49/52). Anywhere else — the gitops repo above all (AC3) — a plain
# Secret is a hard failure. This deliberately doesn't try to classify
# *values* as real-vs-placeholder: distinguishing a real leaked credential
# from "catalog" (a username, not a secret) by grepping text is not a
# reliable thing to build, and a false sense of safety there is worse than
# an honest, simpler check. TruffleHog (already run on every repo's CI)
# is the tool actually suited to catching a real leaked credential; this
# check's job is narrower and more mechanical: plain Secrets stay confined
# to the places already documented as acceptable, and don't silently
# spread to somewhere that isn't.
#
# Usage: ./check-no-plaintext-secrets.sh [dir ...]
#   defaults to this polyrepo's actual manifest locations.
set -euo pipefail

# The PolyRepo root — every repo (STAM-catalog, STAM-gitops, ...) is a
# sibling directory directly under this. Computed from this script's own
# location so it doesn't depend on the caller's working directory.
# Overridable via $REPO_ROOT: CI checks out only this one repo, one level
# too deep for that math (actions/checkout@v4 puts it at
# .../work/STAM-platform/STAM-platform), so ci.yml points REPO_ROOT at
# the checkout's parent directory instead — same gotcha as CLAUDE.md #1a.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

ALLOWED_DIRS=(
  "STAM-catalog/catalog/k8s-local"
  "STAM-booking/booking/k8s-local"
  "STAM-platform/platform/charts/stampede/templates/infra"
)

DIRS=("$@")
if [ ${#DIRS[@]} -eq 0 ]; then
  DIRS=(
    "$REPO_ROOT/STAM-catalog"
    "$REPO_ROOT/STAM-booking"
    "$REPO_ROOT/STAM-identity"
    "$REPO_ROOT/STAM-gateway"
    "$REPO_ROOT/STAM-payment"
    "$REPO_ROOT/STAM-notification"
    "$REPO_ROOT/STAM-platform"
    "$REPO_ROOT/STAM-gitops"
  )
fi

fail=0
for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' file; do
    grep -q '^kind: Secret$' "$file" 2>/dev/null || continue
    rel="$(realpath --relative-to="$REPO_ROOT" "$file")"
    allowed=false
    for allow in "${ALLOWED_DIRS[@]}"; do
      case "$rel" in
        "$allow"/*) allowed=true ;;
      esac
    done
    if [ "$allowed" = true ]; then
      echo "OK (documented kind-local placeholder): $rel"
    else
      echo "FAIL: $rel defines a plain Secret outside the documented kind-local allowlist"
      fail=1
    fi
  done < <(find "$dir" \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
done

exit $fail
