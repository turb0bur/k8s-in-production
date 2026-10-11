#!/usr/bin/env bash
set -euo pipefail

readonly USERS=(mentor student01 student02 student03)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

issue_for_all() {
  local user
  for user in "${USERS[@]}"; do
    "$SCRIPT_DIR/issue-credentials.sh" "$user"
  done
}

main() {
  issue_for_all
}

main "$@"