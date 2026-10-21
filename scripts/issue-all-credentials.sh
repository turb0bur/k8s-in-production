#!/usr/bin/env bash
set -euo pipefail

readonly MENTOR="mentor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

list_users() {
  echo "$MENTOR"
  kubectl get namespaces -l role=student -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

issue_for_all() {
  local user
  for user in $(list_users); do
    "$SCRIPT_DIR/issue-credentials.sh" "$user"
  done
}

main() {
  issue_for_all
}

main "$@"
