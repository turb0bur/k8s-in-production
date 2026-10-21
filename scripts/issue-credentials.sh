#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-}"
readonly CERT_TTL_SECONDS=31536000 # 365 days (365 * 24 * 60 * 60)
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kubeconfigs"
readonly OUT_DIR

check_context() {
  local current
  current="$(kubectl config current-context)"
  echo "using kubectl context '$current'"
  if [[ -n "$EXPECTED_CONTEXT" && "$current" != "$EXPECTED_CONTEXT" ]]; then
    echo "expected context '$EXPECTED_CONTEXT'" >&2
    return 1
  fi
}

generate_key_and_csr() {
  local user="$1"
  openssl genrsa -out "$OUT_DIR/$user.key" 2048
  openssl req -new -key "$OUT_DIR/$user.key" -subj "/CN=$user" -out "$OUT_DIR/$user.csr"
}

submit_csr() {
  local user="$1"
  local request
  request="$(base64 < "$OUT_DIR/$user.csr" | tr -d '\n')"

  kubectl delete csr "$user" --ignore-not-found
  kubectl apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $user
spec:
  request: $request
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $CERT_TTL_SECONDS
  usages:
    - client auth
EOF
}

approve_and_fetch_cert() {
  local user="$1"
  kubectl certificate approve "$user"
  until [[ -n "$(kubectl get csr "$user" -o jsonpath='{.status.certificate}')" ]]; do
    sleep 1
  done
  kubectl get csr "$user" -o jsonpath='{.status.certificate}' | base64 --decode > "$OUT_DIR/$user.crt"
}

build_kubeconfig() {
  local user="$1"
  local kubeconfig="$OUT_DIR/$user.kubeconfig"
  local cluster server ca_file
  cluster="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca_file="$(mktemp)"
  kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 --decode > "$ca_file"

  rm -f "$kubeconfig"
  kubectl config set-cluster "$cluster" --kubeconfig="$kubeconfig" \
    --server="$server" --certificate-authority="$ca_file" --embed-certs=true
  kubectl config set-credentials "$user" --kubeconfig="$kubeconfig" \
    --client-certificate="$OUT_DIR/$user.crt" --client-key="$OUT_DIR/$user.key" --embed-certs=true
  kubectl config set-context "$user@$cluster" --kubeconfig="$kubeconfig" \
    --cluster="$cluster" --user="$user"
  kubectl config use-context "$user@$cluster" --kubeconfig="$kubeconfig"

  rm -f "$ca_file"
  chmod 600 "$kubeconfig" "$OUT_DIR/$user.key"
}

main() {
  local user="${1:?usage: $0 <username>}"
  check_context
  mkdir -p "$OUT_DIR"
  generate_key_and_csr "$user"
  submit_csr "$user"
  approve_and_fetch_cert "$user"
  build_kubeconfig "$user"
  echo "created $OUT_DIR/$user.kubeconfig"
}

main "$@"