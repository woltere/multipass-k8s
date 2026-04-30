#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-${ROOT_DIR}/config/cluster.env}"
ADDONS_CONFIG="${ADDONS_CONFIG:-${ROOT_DIR}/config/addons.env}"

load_cluster_config() {
  if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
  fi

  CLUSTER_NAME="${CLUSTER_NAME:-mks}"
  CONTROL_PLANES="${CONTROL_PLANES:-1}"
  WORKERS="${WORKERS:-2}"
  IMAGE="${IMAGE:-24.04}"
  CPUS="${CPUS:-2}"
  MEMORY="${MEMORY:-4G}"
  DISK="${DISK:-25G}"
  KUBERNETES_MINOR="${KUBERNETES_MINOR:-1.35}"
  KUBERNETES_VERSION="${KUBERNETES_VERSION:-${K8S_VERSION:-latest}}"
  POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
  SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
  CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
  STATE_DIR="${STATE_DIR:-.state}"
  KUBECONFIG_PATH="${KUBECONFIG_PATH:-${STATE_DIR}/kubeconfig}"

  case "$STATE_DIR" in
    /*) ;;
    *) STATE_DIR="${ROOT_DIR}/${STATE_DIR#./}" ;;
  esac

  case "$KUBECONFIG_PATH" in
    /*) ;;
    *) KUBECONFIG_PATH="${ROOT_DIR}/${KUBECONFIG_PATH#./}" ;;
  esac
}

load_addons_config() {
  if [[ -f "$ADDONS_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$ADDONS_CONFIG"
  fi

  CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
  CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
  CILIUM_WAIT="${CILIUM_WAIT:-true}"
  CILIUM_EXTRA_ARGS="${CILIUM_EXTRA_ARGS:-}"
  CILIUM_HELM_EXTRA_ARGS="${CILIUM_HELM_EXTRA_ARGS:-}"
  APPARMOR_PROFILE_NAME="${APPARMOR_PROFILE_NAME:-k8s-deny-write}"
  APPARMOR_PROFILE_PATH="${APPARMOR_PROFILE_PATH:-profiles/apparmor/k8s-deny-write}"
  APPARMOR_DEMO_MANIFEST="${APPARMOR_DEMO_MANIFEST:-k8s/apparmor/deny-write-demo.yaml}"
  FALCO_NAMESPACE="${FALCO_NAMESPACE:-falco}"
  FALCO_HELM_EXTRA_ARGS="${FALCO_HELM_EXTRA_ARGS:---set tty=true}"
  TRIVY_NAMESPACE="${TRIVY_NAMESPACE:-trivy-system}"
  TRIVY_VALUES_FILE="${TRIVY_VALUES_FILE:-config/trivy-operator-values.yaml}"
  TRIVY_HELM_EXTRA_ARGS="${TRIVY_HELM_EXTRA_ARGS:-}"
  KUBE_BENCH_NAMESPACE="${KUBE_BENCH_NAMESPACE:-security-tools}"
  KUBE_BENCH_IMAGE="${KUBE_BENCH_IMAGE:-aquasec/kube-bench:latest}"
  REPORTS_DIR="${REPORTS_DIR:-reports}"
  FALCO_LOG_LINES="${FALCO_LOG_LINES:-200}"
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

maybe_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok     %s\n' "$1"
  else
    printf 'missing %s\n' "$1"
  fi
}

node_name() {
  local role="$1"
  local index="$2"
  case "$role" in
    cp) printf '%s-cp-%s' "$CLUSTER_NAME" "$index" ;;
    worker) printf '%s-worker-%s' "$CLUSTER_NAME" "$index" ;;
    *) die "unknown node role: $role" ;;
  esac
}

all_nodes() {
  local i
  for ((i = 1; i <= CONTROL_PLANES; i++)); do
    node_name cp "$i"
    printf '\n'
  done
  for ((i = 1; i <= WORKERS; i++)); do
    node_name worker "$i"
    printf '\n'
  done
}

cluster_instances() {
  {
    all_nodes
    if command -v multipass >/dev/null 2>&1; then
      multipass list --format csv 2>/dev/null \
        | awk -F, -v prefix="${CLUSTER_NAME}-" 'NR > 1 && $1 ~ "^" prefix "(cp|worker)-[0-9]+$" { print $1 }'
    fi
  } | awk 'NF && !seen[$0]++'
}

instance_exists() {
  multipass info "$1" >/dev/null 2>&1
}

mp_exec() {
  local node="$1"
  shift
  multipass exec "$node" -- "$@"
}

node_ip() {
  multipass info "$1" --format json \
    | awk -F'"' '/"ipv4"/ {getline; print $2; exit}'
}

require_cluster_instances() {
  local node
  for node in $(all_nodes); do
    instance_exists "$node" || die "Multipass instance does not exist: $node"
  done
}

require_kubeconfig() {
  [[ -f "$KUBECONFIG_PATH" ]] || die "missing kubeconfig at $KUBECONFIG_PATH; run make kubeconfig or make create"
}
