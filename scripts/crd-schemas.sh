#!/usr/bin/env bash
# Build kubeconform JSON schemas from the CRDs of the exact versions this lab pins:
#   Flux (install.yaml of the release), Keptn chart, kube-prometheus-stack chart.
# Output layout: <SCHEMA_DIR>/<group>/<kind>_<version>.json (kubeconform's
# {{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}} template).
# Objects get "additionalProperties: false" unless the CRD allows unknown fields,
# so kubeconform -strict also catches misspelled fields in custom resources.
# Needs: curl, helm, yq, jq.
set -euo pipefail

: "${FLUX_VERSION:?}" "${KEPTN_CHART_VERSION:?}" "${KPS_CHART_VERSION:?}"
SCHEMA_DIR="${SCHEMA_DIR:-.tools/schemas}"
KEPTN_REPO="${KEPTN_REPO:-https://charts.lifecycle.keptn.sh}"
KPS_CHART="${KPS_CHART:-oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack}"

for t in curl helm yq jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (run 'make tools')" >&2; exit 1; }
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Keep helm's repository and registry state out of the user's home.
export HELM_CONFIG_HOME="$tmp/helm/config" HELM_CACHE_HOME="$tmp/helm/cache" HELM_DATA_HOME="$tmp/helm/data"

# Flux: CRDs from the release's install.yaml, verified against the release checksums.
flux_dl="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"
curl -fsSL --retry 3 -o "$tmp/flux.yaml" "$flux_dl/install.yaml"
curl -fsSL --retry 3 -o "$tmp/flux.sums" "$flux_dl/flux_${FLUX_VERSION}_checksums.txt"
want="$(awk '$2 == "install.yaml" {print $1}' "$tmp/flux.sums")"
[[ -n "$want" && "$want" == "$(sha256 "$tmp/flux.yaml")" ]] || { echo "flux install.yaml checksum mismatch" >&2; exit 1; }

# Keptn: render the chart (CRDs are templates in its subcharts), verified against the index digest.
curl -fsSL --retry 3 -o "$tmp/keptn-index.yaml" "$KEPTN_REPO/index.yaml"
keptn_url="$(V="$KEPTN_CHART_VERSION" yq '.entries.keptn[] | select(.version == strenv(V)) | .urls[0]' "$tmp/keptn-index.yaml")"
keptn_digest="$(V="$KEPTN_CHART_VERSION" yq '.entries.keptn[] | select(.version == strenv(V)) | .digest' "$tmp/keptn-index.yaml")"
[[ -n "$keptn_url" && "$keptn_url" != null ]] || { echo "keptn chart $KEPTN_CHART_VERSION not in $KEPTN_REPO" >&2; exit 1; }
curl -fsSL --retry 3 -o "$tmp/keptn.tgz" "$keptn_url"
[[ "$keptn_digest" == "$(sha256 "$tmp/keptn.tgz")" ]] || { echo "keptn chart digest mismatch" >&2; exit 1; }
helm template keptn "$tmp/keptn.tgz" --namespace keptn-system --include-crds > "$tmp/keptn.yaml"

# kube-prometheus-stack: prometheus-operator CRDs shipped as plain files in the chart.
helm pull "$KPS_CHART" --version "$KPS_CHART_VERSION" --destination "$tmp" >/dev/null 2>&1
tar -xzf "$tmp/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz" -C "$tmp" \
  kube-prometheus-stack/charts/crds/crds
cat "$tmp"/kube-prometheus-stack/charts/crds/crds/*.yaml > "$tmp/kps.yaml"

rm -rf "$SCHEMA_DIR"
mkdir -p "$SCHEMA_DIR"
count=0
for src in "$tmp/flux.yaml" "$tmp/keptn.yaml" "$tmp/kps.yaml"; do
  # One compact JSON line per CRD.
  while IFS= read -r crd; do
    [[ -z "$crd" ]] && continue
    group="$(jq -r '.spec.group' <<<"$crd")"
    kind="$(jq -r '.spec.names.kind | ascii_downcase' <<<"$crd")"
    mkdir -p "$SCHEMA_DIR/$group"
    while IFS= read -r version; do
      jq --arg v "$version" '
        .spec.versions[] | select(.name == $v) | .schema.openAPIV3Schema
        | walk(if type == "object" and has("properties") and (has("additionalProperties") | not)
                  and ((.["x-kubernetes-preserve-unknown-fields"] // false) | not)
               then .additionalProperties = false else . end)' <<<"$crd" \
        > "$SCHEMA_DIR/$group/${kind}_${version}.json"
      count=$((count + 1))
    done < <(jq -r '.spec.versions[].name' <<<"$crd")
  done < <(yq -o=json -I=0 'select(.kind == "CustomResourceDefinition")' "$src")
done
echo "wrote $count CRD schemas to $SCHEMA_DIR"
