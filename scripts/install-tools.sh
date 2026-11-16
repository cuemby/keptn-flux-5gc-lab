#!/usr/bin/env bash
# Install the pinned validation tools into a local directory (default .tools/bin).
# Every download is checked against the checksum file published with the same release.
# Versions come from the Makefile (KUSTOMIZE_VERSION, KUBECONFORM_VERSION, ...).
set -euo pipefail

: "${KUSTOMIZE_VERSION:?}" "${KUBECONFORM_VERSION:?}" "${YQ_VERSION:?}"
: "${ACTIONLINT_VERSION:?}" "${GITLEAKS_VERSION:?}"
BIN_DIR="${BIN_DIR:-.tools/bin}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
case "$os" in
  linux | darwin) ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$BIN_DIR"

# fetch <url> <checksum-file-url> <asset-name>: download and verify one release asset.
fetch() {
  local url=$1 sums_url=$2 asset=$3 want got
  curl -fsSL --retry 3 -o "$tmp/$asset" "$url"
  curl -fsSL --retry 3 -o "$tmp/sums" "$sums_url"
  # Handles both "<hash>  <file>" and BSD "SHA256 (<file>) = <hash>" formats.
  want="$(awk -v f="$asset" '($2 == f || $2 == "*" f) {print $1} ($1 == "SHA256" && $2 == "(" f ")") {print $4}' "$tmp/sums" | head -n1)"
  got="$(sha256 "$tmp/$asset")"
  if [[ -z "$want" || "$want" != "$got" ]]; then
    echo "checksum mismatch for $asset (want '${want:-none}', got '$got')" >&2
    exit 1
  fi
}

gh_dl=https://github.com

asset="kustomize_v${KUSTOMIZE_VERSION}_${os}_${arch}.tar.gz"
fetch "$gh_dl/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/$asset" \
  "$gh_dl/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/checksums.txt" "$asset"
tar -xzf "$tmp/$asset" -C "$BIN_DIR" kustomize

asset="kubeconform-${os}-${arch}.tar.gz"
fetch "$gh_dl/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/$asset" \
  "$gh_dl/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/CHECKSUMS" "$asset"
tar -xzf "$tmp/$asset" -C "$BIN_DIR" kubeconform

asset="yq_${os}_${arch}"
fetch "$gh_dl/mikefarah/yq/releases/download/v${YQ_VERSION}/$asset" \
  "$gh_dl/mikefarah/yq/releases/download/v${YQ_VERSION}/checksums-bsd" "$asset"
install -m 0755 "$tmp/$asset" "$BIN_DIR/yq"

asset="actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"
fetch "$gh_dl/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/$asset" \
  "$gh_dl/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" "$asset"
tar -xzf "$tmp/$asset" -C "$BIN_DIR" actionlint

gl_arch=$arch
[[ "$arch" == amd64 ]] && gl_arch=x64
asset="gitleaks_${GITLEAKS_VERSION}_${os}_${gl_arch}.tar.gz"
fetch "$gh_dl/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/$asset" \
  "$gh_dl/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_checksums.txt" "$asset"
tar -xzf "$tmp/$asset" -C "$BIN_DIR" gitleaks

echo "tools installed in $BIN_DIR"
