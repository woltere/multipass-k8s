#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_cluster_config
load_hardening_config

export KUBECONFIG="$KUBECONFIG_PATH"

usage() {
  cat <<'USAGE'
Hardening tasks for the Multipass Kubernetes lab

Usage:
  ./scripts/hardening.sh harden
  ./scripts/hardening.sh audit
  ./scripts/hardening.sh encryption-migrate
USAGE
}

control_plane_nodes() {
  local i
  for ((i = 1; i <= CONTROL_PLANES; i++)); do
    node_name cp "$i"
    printf '\n'
  done
}

local_encryption_config_path() {
  printf '%s/encryption-provider-config.yaml' "$STATE_DIR"
}

generate_resource_lines() {
  local resource
  for resource in $ENCRYPTION_RESOURCES; do
    printf '      - %s\n' "$resource"
  done
}

generate_encryption_config() {
  local path="$1"
  local secret="$2"

  case "$ENCRYPTION_PROVIDER" in
    secretbox|aescbc) ;;
    *) die "unsupported ENCRYPTION_PROVIDER: $ENCRYPTION_PROVIDER" ;;
  esac

  {
    cat <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
EOF
    generate_resource_lines
    cat <<EOF
    providers:
      - ${ENCRYPTION_PROVIDER}:
          keys:
            - name: ${ENCRYPTION_KEY_NAME}
              secret: ${secret}
      - identity: {}
EOF
  } >"$path"
  chmod 0600 "$path"
}

ensure_local_encryption_config() {
  local path
  path="$(local_encryption_config_path)"
  mkdir -p "$STATE_DIR"

  if [[ -f "$path" ]]; then
    chmod 0600 "$path"
    log "Using existing encryption provider config at $path"
    return
  fi

  need_cmd openssl
  local secret
  secret="$(openssl rand -base64 32)"
  log "Generating encryption provider config at $path"
  generate_encryption_config "$path" "$secret"
}

install_encryption_config() {
  local node="$1"
  local local_path
  local remote_tmp="/tmp/encryption-provider-config.yaml"
  local_path="$(local_encryption_config_path)"

  log "Installing encryption provider config on $node"
  multipass transfer "$local_path" "${node}:${remote_tmp}"
  mp_exec "$node" sudo install -o root -g root -m 0600 "$remote_tmp" "$ENCRYPTION_CONFIG_PATH"
  mp_exec "$node" rm -f "$remote_tmp"
}

resolve_repo_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "${1#./}" ;;
  esac
}

audit_log_dir() {
  dirname "$AUDIT_LOG_PATH"
}

install_audit_policy() {
  local node="$1"
  local policy_source
  local policy_dir
  local remote_tmp="/tmp/audit-policy.yaml"
  local log_dir

  policy_source="$(resolve_repo_path "$AUDIT_POLICY_SOURCE")"
  policy_dir="$(dirname "$AUDIT_POLICY_PATH")"
  log_dir="$(audit_log_dir)"

  [[ -f "$policy_source" ]] || die "audit policy file not found: $policy_source"

  log "Installing audit policy on $node"
  multipass transfer "$policy_source" "${node}:${remote_tmp}"
  mp_exec "$node" sudo install -d -o root -g root -m 0755 "$policy_dir"
  mp_exec "$node" sudo install -o root -g root -m 0600 "$remote_tmp" "$AUDIT_POLICY_PATH"
  mp_exec "$node" sudo install -d -o root -g root -m 0700 "$log_dir"
  mp_exec "$node" rm -f "$remote_tmp"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

patch_apiserver_manifest() {
  local node="$1"
  local manifest_dir
  local manifest
  local patch
  local empty_patch
  local patched
  local remote_manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  local remote_copy="/tmp/kube-apiserver.$$.yaml"
  local remote_patched="/tmp/kube-apiserver.$$.patched.yaml"
  local volume_name="encryption-provider-config"
  local expected_config_arg="--encryption-provider-config=${ENCRYPTION_CONFIG_PATH}"
  local existing_config_arg=""
  local encryption_mount_name=""
  local encryption_volume_name=""
  local first_patch="true"

  log "Patching kube-apiserver manifest on $node"

  manifest_dir="$(mktemp -d "${TMPDIR:-/tmp}/k8s-hardening.XXXXXX")"
  manifest="${manifest_dir}/kube-apiserver.yaml"
  patch="${manifest_dir}/patch.json"
  empty_patch="${manifest_dir}/empty-patch.json"
  patched="${manifest_dir}/kube-apiserver.patched.yaml"

  mp_exec "$node" sudo cp "$remote_manifest" "$remote_copy"
  mp_exec "$node" sudo chmod 0644 "$remote_copy"
  multipass transfer "${node}:${remote_copy}" "$manifest"
  mp_exec "$node" sudo rm -f "$remote_copy"
  printf '[]\n' >"$empty_patch"

  manifest_jsonpath() {
    local expression="$1"
    kubectl patch --local --dry-run=client --type=json -f "$manifest" --patch-file "$empty_patch" -o=jsonpath="$expression"
  }

  for arg in $(manifest_jsonpath '{.spec.containers[0].command[*]}'); do
    case "$arg" in
      --encryption-provider-config=*)
        existing_config_arg="$arg"
        ;;
    esac
  done

  if [[ -n "$existing_config_arg" && "$existing_config_arg" != "$expected_config_arg" ]]; then
    die "$node already uses a different encryption provider config: $existing_config_arg"
  fi

  encryption_mount_name="$(manifest_jsonpath "{.spec.containers[0].volumeMounts[?(@.mountPath==\"${ENCRYPTION_CONFIG_PATH}\")].name}")"
  encryption_volume_name="$(manifest_jsonpath "{.spec.volumes[?(@.hostPath.path==\"${ENCRYPTION_CONFIG_PATH}\")].name}")"

  printf '[\n' >"$patch"

  add_patch_op() {
    local op="$1"
    local path="$2"
    local value="$3"
    if [[ "$first_patch" == "true" ]]; then
      first_patch="false"
    else
      printf ',\n' >>"$patch"
    fi
    printf '  {"op":"%s","path":"%s","value":%s}' "$(json_escape "$op")" "$(json_escape "$path")" "$value" >>"$patch"
  }

  if [[ -z "$existing_config_arg" ]]; then
    add_patch_op "add" "/spec/containers/0/command/-" "\"$(json_escape "$expected_config_arg")\""
  fi

  if [[ -z "$encryption_mount_name" ]]; then
    add_patch_op "add" "/spec/containers/0/volumeMounts/-" "{\"mountPath\":\"$(json_escape "$ENCRYPTION_CONFIG_PATH")\",\"name\":\"$(json_escape "$volume_name")\",\"readOnly\":true}"
  fi

  if [[ -z "$encryption_volume_name" ]]; then
    add_patch_op "add" "/spec/volumes/-" "{\"hostPath\":{\"path\":\"$(json_escape "$ENCRYPTION_CONFIG_PATH")\",\"type\":\"File\"},\"name\":\"$(json_escape "$volume_name")\"}"
  fi

  if [[ "$first_patch" == "true" ]]; then
    log "kube-apiserver manifest already configured on $node"
    rm -rf "$manifest_dir"
    return
  fi

  printf '\n]\n' >>"$patch"

  kubectl patch --local --dry-run=client -o yaml --type=json -f "$manifest" --patch-file "$patch" >"$patched"

  if cmp -s "$manifest" "$patched"; then
    log "kube-apiserver manifest already configured on $node"
    rm -rf "$manifest_dir"
    return
  fi

  multipass transfer "$patched" "${node}:${remote_patched}"
  mp_exec "$node" sudo bash -s -- "$remote_manifest" "$remote_patched" <<'REMOTE'
set -euo pipefail

manifest="$1"
patched="$2"
backup="${manifest}.bak.$(date +%Y%m%d%H%M%S)"

cp -p "$manifest" "$backup"
install -o root -g root -m 0644 "$patched" "$manifest"
rm -f "$patched"
echo "updated kube-apiserver manifest; backup: $backup"
REMOTE

  rm -rf "$manifest_dir"
}

patch_apiserver_audit_manifest() {
  local node="$1"
  local manifest_dir
  local manifest
  local patch
  local empty_patch
  local patched
  local remote_manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
  local remote_copy="/tmp/kube-apiserver.$$.yaml"
  local remote_patched="/tmp/kube-apiserver.$$.patched.yaml"
  local policy_volume_name="audit-policy"
  local log_volume_name="audit-log"
  local log_dir
  local audit_mount_name=""
  local audit_volume_name=""
  local audit_log_mount_name=""
  local audit_log_volume_name=""
  local first_patch="true"

  log "Patching kube-apiserver audit manifest on $node"

  manifest_dir="$(mktemp -d "${TMPDIR:-/tmp}/k8s-hardening-audit.XXXXXX")"
  manifest="${manifest_dir}/kube-apiserver.yaml"
  patch="${manifest_dir}/patch.json"
  empty_patch="${manifest_dir}/empty-patch.json"
  patched="${manifest_dir}/kube-apiserver.patched.yaml"
  log_dir="$(audit_log_dir)"

  mp_exec "$node" sudo cp "$remote_manifest" "$remote_copy"
  mp_exec "$node" sudo chmod 0644 "$remote_copy"
  multipass transfer "${node}:${remote_copy}" "$manifest"
  mp_exec "$node" sudo rm -f "$remote_copy"
  printf '[]\n' >"$empty_patch"

  manifest_jsonpath() {
    local expression="$1"
    kubectl patch --local --dry-run=client --type=json -f "$manifest" --patch-file "$empty_patch" -o=jsonpath="$expression"
  }

  ensure_apiserver_arg() {
    local flag="$1"
    local expected="$2"
    local arg
    local existing=""

    for arg in $(manifest_jsonpath '{.spec.containers[0].command[*]}'); do
      case "$arg" in
        "${flag}"=*)
          existing="$arg"
          ;;
      esac
    done

    if [[ -n "$existing" && "$existing" != "$expected" ]]; then
      die "$node already uses a different ${flag}: $existing"
    fi

    if [[ -z "$existing" ]]; then
      add_patch_op "add" "/spec/containers/0/command/-" "\"$(json_escape "$expected")\""
    fi
  }

  add_patch_op() {
    local op="$1"
    local path="$2"
    local value="$3"
    if [[ "$first_patch" == "true" ]]; then
      first_patch="false"
    else
      printf ',\n' >>"$patch"
    fi
    printf '  {"op":"%s","path":"%s","value":%s}' "$(json_escape "$op")" "$(json_escape "$path")" "$value" >>"$patch"
  }

  audit_mount_name="$(manifest_jsonpath "{.spec.containers[0].volumeMounts[?(@.mountPath==\"${AUDIT_POLICY_PATH}\")].name}")"
  audit_volume_name="$(manifest_jsonpath "{.spec.volumes[?(@.hostPath.path==\"${AUDIT_POLICY_PATH}\")].name}")"
  audit_log_mount_name="$(manifest_jsonpath "{.spec.containers[0].volumeMounts[?(@.mountPath==\"${log_dir}\")].name}")"
  audit_log_volume_name="$(manifest_jsonpath "{.spec.volumes[?(@.hostPath.path==\"${log_dir}\")].name}")"

  printf '[\n' >"$patch"

  ensure_apiserver_arg "--audit-policy-file" "--audit-policy-file=${AUDIT_POLICY_PATH}"
  ensure_apiserver_arg "--audit-log-path" "--audit-log-path=${AUDIT_LOG_PATH}"
  ensure_apiserver_arg "--audit-log-maxage" "--audit-log-maxage=${AUDIT_LOG_MAXAGE}"
  ensure_apiserver_arg "--audit-log-maxbackup" "--audit-log-maxbackup=${AUDIT_LOG_MAXBACKUP}"
  ensure_apiserver_arg "--audit-log-maxsize" "--audit-log-maxsize=${AUDIT_LOG_MAXSIZE}"

  if [[ -z "$audit_mount_name" ]]; then
    add_patch_op "add" "/spec/containers/0/volumeMounts/-" "{\"mountPath\":\"$(json_escape "$AUDIT_POLICY_PATH")\",\"name\":\"$(json_escape "$policy_volume_name")\",\"readOnly\":true}"
  fi

  if [[ -z "$audit_volume_name" ]]; then
    add_patch_op "add" "/spec/volumes/-" "{\"hostPath\":{\"path\":\"$(json_escape "$AUDIT_POLICY_PATH")\",\"type\":\"File\"},\"name\":\"$(json_escape "$policy_volume_name")\"}"
  fi

  if [[ -z "$audit_log_mount_name" ]]; then
    add_patch_op "add" "/spec/containers/0/volumeMounts/-" "{\"mountPath\":\"$(json_escape "$log_dir")\",\"name\":\"$(json_escape "$log_volume_name")\"}"
  fi

  if [[ -z "$audit_log_volume_name" ]]; then
    add_patch_op "add" "/spec/volumes/-" "{\"hostPath\":{\"path\":\"$(json_escape "$log_dir")\",\"type\":\"DirectoryOrCreate\"},\"name\":\"$(json_escape "$log_volume_name")\"}"
  fi

  if [[ "$first_patch" == "true" ]]; then
    log "kube-apiserver audit manifest already configured on $node"
    rm -rf "$manifest_dir"
    return
  fi

  printf '\n]\n' >>"$patch"

  kubectl patch --local --dry-run=client -o yaml --type=json -f "$manifest" --patch-file "$patch" >"$patched"

  if cmp -s "$manifest" "$patched"; then
    log "kube-apiserver audit manifest already configured on $node"
    rm -rf "$manifest_dir"
    return
  fi

  multipass transfer "$patched" "${node}:${remote_patched}"
  mp_exec "$node" sudo bash -s -- "$remote_manifest" "$remote_patched" <<'REMOTE'
set -euo pipefail

manifest="$1"
patched="$2"
backup="${manifest}.bak.$(date +%Y%m%d%H%M%S)"

cp -p "$manifest" "$backup"
install -o root -g root -m 0644 "$patched" "$manifest"
rm -f "$patched"
echo "updated kube-apiserver manifest; backup: $backup"
REMOTE

  rm -rf "$manifest_dir"
}

wait_apiserver_ready() {
  local attempt
  log "Waiting for Kubernetes API readiness"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done
  die "timed out waiting for Kubernetes API readiness"
}

enable_encryption() {
  require_cluster_instances
  require_kubeconfig
  need_cmd kubectl
  need_cmd multipass

  ensure_local_encryption_config

  local node
  for node in $(control_plane_nodes); do
    install_encryption_config "$node"
    patch_apiserver_manifest "$node"
    wait_apiserver_ready
  done

  log "API server encryption provider config enabled"
}

enable_audit_logging() {
  require_cluster_instances
  require_kubeconfig
  need_cmd kubectl
  need_cmd multipass

  local policy_source
  policy_source="$(resolve_repo_path "$AUDIT_POLICY_SOURCE")"
  [[ -f "$policy_source" ]] || die "audit policy file not found: $policy_source"

  local node
  for node in $(control_plane_nodes); do
    install_audit_policy "$node"
    patch_apiserver_audit_manifest "$node"
    wait_apiserver_ready
  done

  log "API server audit logging enabled"
}

migrate_encrypted_secrets() {
  require_kubeconfig
  need_cmd kubectl

  log "Rewriting Secrets so they are stored with the active encryption provider"
  kubectl get secrets --all-namespaces -o json | kubectl replace -f -
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  harden) enable_encryption ;;
  audit) enable_audit_logging ;;
  encryption-migrate) migrate_encrypted_secrets ;;
  *) die "unknown command: ${1:-}" ;;
esac
