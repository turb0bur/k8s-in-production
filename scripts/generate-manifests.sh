#!/usr/bin/env bash
set -euo pipefail

readonly MENTOR="mentor"
readonly STUDENT_PREFIX="student"
readonly BASE_ROLE="ns-rw"
COUNT=""
ADDITIONAL_GRANTS_FILE=""

usage() {
  echo "usage: $0 <number-of-students> [--additional-grants FILE]" >&2
}

parse_args() {
  COUNT="${1:-}"
  if [[ -z "$COUNT" ]]; then
    usage
    return 1
  fi
  shift
  while (($#)); do
    case "$1" in
      --additional-grants) ADDITIONAL_GRANTS_FILE="${2:?--additional-grants needs a file}"; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; return 1 ;;
    esac
  done
  if [[ ! "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "number of students must be a positive integer, got '$COUNT'" >&2
    return 1
  fi
  if [[ -n "$ADDITIONAL_GRANTS_FILE" && ! -f "$ADDITIONAL_GRANTS_FILE" ]]; then
    echo "additional grants file not found: $ADDITIONAL_GRANTS_FILE" >&2
    return 1
  fi
}

student_names() {
  local i
  for ((i = 1; i <= COUNT; i++)); do
    printf '%s%02d\n' "$STUDENT_PREFIX" "$i"
  done
}

namespace() {
  local name="$1" role="$2"
  cat <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $name
  labels:
    role: $role
EOF
}

rolebinding() {
  local user="$1" namespace="$2" role="$3"
  cat <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $user-$role
  namespace: $namespace
subjects:
  - kind: User
    name: $user
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: $role
  apiGroup: rbac.authorization.k8s.io
EOF
}

generate_namespaces() {
  local student
  namespace "$MENTOR" "$MENTOR"
  for student in $(student_names); do
    namespace "$student" student
  done
}

generate_baseline_bindings() {
  local student
  rolebinding "$MENTOR" "$MENTOR" "$BASE_ROLE"
  for student in $(student_names); do
    rolebinding "$MENTOR" "$student" "$BASE_ROLE"
    rolebinding "$student" "$student" "$BASE_ROLE"
  done
}

generate_additional_grants() {
  [[ -n "$ADDITIONAL_GRANTS_FILE" ]] || return 0
  local line line_no=0 user role namespaces extra ns
  local -a ns_list
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    ((line_no > 1)) || continue
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    IFS=',' read -r user role namespaces extra <<<"$line"
    if [[ -z "$user" || -z "$role" || -z "$namespaces" || -n "$extra" ]]; then
      echo "$ADDITIONAL_GRANTS_FILE:$line_no: expected 'user,role,namespace[;namespace...]'" >&2
      return 1
    fi
    IFS=';' read -ra ns_list <<<"$namespaces"
    for ns in "${ns_list[@]}"; do
      rolebinding "$user" "$ns" "$role"
    done
  done < "$ADDITIONAL_GRANTS_FILE"
}

main() {
  parse_args "$@"
  generate_namespaces
  generate_baseline_bindings
  generate_additional_grants
}

main "$@"
