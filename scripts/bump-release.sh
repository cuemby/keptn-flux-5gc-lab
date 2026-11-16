#!/usr/bin/env bash
# Write a new UTC-timestamp RELEASE_ID into clusters/<stage>/apps.yaml.
# Flux substitutes it into keptn.sh/version on the AMF, SMF, NSSF and UPF pod
# templates, so Keptn sees a new workload version and runs the lifecycle.
# Usage: scripts/bump-release.sh [stage]   (default: lab). Does not commit.
set -euo pipefail

STAGE="${1:-lab}"
[[ "$STAGE" =~ ^[a-z0-9-]+$ ]] || { echo "invalid stage: $STAGE" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"
FILE="clusters/$STAGE/apps.yaml"
[[ -f "$FILE" ]] || { echo "missing $FILE" >&2; exit 1; }
grep -qE '^[[:space:]]*RELEASE_ID:' "$FILE" || { echo "no RELEASE_ID in $FILE" >&2; exit 1; }

RELEASE_ID="$STAGE-$(date -u +%Y%m%d-%H%M%S)"
sed -i.bak -E "s/^([[:space:]]*RELEASE_ID:[[:space:]]*)\"[^\"]*\"/\1\"$RELEASE_ID\"/" "$FILE"
rm -f "$FILE.bak"
grep -q "\"$RELEASE_ID\"" "$FILE" || { echo "failed to update RELEASE_ID in $FILE" >&2; exit 1; }
echo "$RELEASE_ID"
