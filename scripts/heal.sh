#!/usr/bin/env bash
# Restore the good Open5GS config.
# Points the open5gs-values ConfigMap at values/open5gs-good.yaml, bumps RELEASE_ID, then
# commits and pushes so Flux applies it and Keptn evaluates the new release.
# Usage: scripts/heal.sh [stage]   (default: lab). Set NO_PUSH=1 to commit only.
set -euo pipefail

STAGE="${1:-lab}"
cd "$(git rev-parse --show-toplevel)"
KUST=apps/open5gs/kustomization.yaml
FROM="values.yaml=values/open5gs-fault-plmn.yaml"
TO="values.yaml=values/open5gs-good.yaml"

if grep -qF "$TO" "$KUST"; then
  echo "$KUST already uses values/open5gs-good.yaml; bumping RELEASE_ID only"
else
  grep -qF "$FROM" "$KUST" || { echo "$KUST does not reference values/open5gs-fault-plmn.yaml" >&2; exit 1; }
  sed -i.bak "s|$FROM|$TO|" "$KUST"
  rm -f "$KUST.bak"
fi

RELEASE_ID="$(scripts/bump-release.sh "$STAGE")"
git add "$KUST" "clusters/$STAGE/apps.yaml"
git commit -m "Restore good Open5GS config on $STAGE (RELEASE_ID $RELEASE_ID)"
if [[ "${NO_PUSH:-0}" != "1" ]]; then
  git push
fi
echo "released $RELEASE_ID with values/open5gs-good.yaml"
