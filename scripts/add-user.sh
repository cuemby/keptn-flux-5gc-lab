#!/usr/bin/env bash
# Issue a lab user a client certificate valid for 7 days and write a kubeconfig for it.
#   scripts/add-user.sh <name> <group>
#   <group>: lab:viewers | lab:keptn-authors | lab:5gc-operators | lab:platform-admins
# The certificate's CN is the user name and its O is the group, which bindings in
# infrastructure/rbac/bindings.yaml map to permissions. The private key never leaves this machine
# and the kubeconfig lands in users/<name>.kubeconfig at the repository root (git-ignored), with
# the user's namespace set to open5gs. Needs kubectl with
# cluster-admin on the current context, and openssl.
#
# A certificate cannot be revoked before it expires: remove access sooner by deleting the group
# binding or, in a lab, by recreating the cluster.
set -euo pipefail

usage() { echo "usage: $0 <name> <lab:viewers|lab:keptn-authors|lab:5gc-operators|lab:platform-admins>" >&2; exit 1; }
[[ $# -eq 2 ]] || usage
NAME="$1"
GROUP="$2"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "invalid name: $NAME (lowercase letters, digits, '-')" >&2; exit 1; }
case "$GROUP" in
  lab:viewers|lab:keptn-authors|lab:5gc-operators|lab:platform-admins) ;;
  *) usage ;;
esac

for t in kubectl openssl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 1; }
done

# users/ at the repository root (next to scripts/), whatever the current directory is.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT_DIR="users"
KEY="$OUT_DIR/$NAME.key"
KUBECONFIG_OUT="$OUT_DIR/$NAME.kubeconfig"
CSR_NAME="lab-user-$NAME"
EXPIRATION_SECONDS=604800   # 7 days

umask 077
mkdir -p "$OUT_DIR"
[[ -e "$KEY" ]] || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY" 2>/dev/null
CSR_PEM="$(openssl req -new -key "$KEY" -subj "/CN=$NAME/O=$GROUP")"

# Replace a pending or old request with the same name.
kubectl delete csr "$CSR_NAME" --ignore-not-found >/dev/null
kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $CSR_NAME
spec:
  request: $(printf '%s' "$CSR_PEM" | base64 | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $EXPIRATION_SECONDS
  usages: [client auth]
EOF
kubectl certificate approve "$CSR_NAME" >/dev/null

CERT=""
for _ in $(seq 1 30); do
  CERT="$(kubectl get csr "$CSR_NAME" -o jsonpath='{.status.certificate}')"
  [[ -n "$CERT" ]] && break
  sleep 1
done
[[ -n "$CERT" ]] || { echo "certificate for $NAME was not issued (is the signer running?)" >&2; exit 1; }
kubectl delete csr "$CSR_NAME" >/dev/null

CLUSTER="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$CA_DATA" ]] || { echo "current context has no inline certificate-authority-data" >&2; exit 1; }

rm -f "$KUBECONFIG_OUT"
export KUBECONFIG="$KUBECONFIG_OUT"
kubectl config set-cluster "$CLUSTER" --server="$SERVER" >/dev/null
kubectl config set "clusters.$CLUSTER.certificate-authority-data" "$CA_DATA" >/dev/null
kubectl config set "users.$NAME.client-certificate-data" "$CERT" >/dev/null
kubectl config set "users.$NAME.client-key-data" "$(base64 < "$KEY" | tr -d '\n')" >/dev/null
kubectl config set-context "$NAME@$CLUSTER" --cluster="$CLUSTER" --user="$NAME" --namespace=open5gs >/dev/null
kubectl config use-context "$NAME@$CLUSTER" >/dev/null

echo "wrote $KUBECONFIG_OUT ($NAME in $GROUP, valid for 7 days)"
echo "try: KUBECONFIG=$KUBECONFIG_OUT kubectl auth whoami"
