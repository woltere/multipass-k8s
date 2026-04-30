#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_cluster_config
load_addons_config

export KUBECONFIG="$KUBECONFIG_PATH"

TRIVY_REPORT_KINDS=(
  vulnerabilityreports
  configauditreports
  rbacassessmentreports
  infraassessmentreports
  exposedsecretreports
  clustercompliancereports
)

usage() {
  cat <<'USAGE'
CKS report helpers

Usage:
  ./scripts/reports.sh all
  ./scripts/reports.sh falco
  ./scripts/reports.sh trivy
  ./scripts/reports.sh kube-bench
  ./scripts/reports.sh save
USAGE
}

require_reports_tools() {
  require_kubeconfig
  need_cmd kubectl
}

section() {
  printf '\n## %s\n\n' "$*"
}

falco_report() {
  require_reports_tools

  section "Falco Pods"
  kubectl get pods -n "$FALCO_NAMESPACE" -o wide

  section "Falco Logs"
  if ! kubectl logs -n "$FALCO_NAMESPACE" \
    -l app.kubernetes.io/name=falco \
    --tail="$FALCO_LOG_LINES" \
    --prefix; then
    printf 'No Falco logs found using label app.kubernetes.io/name=falco in namespace %s.\n' "$FALCO_NAMESPACE" >&2
    return 1
  fi
}

trivy_reports() {
  require_reports_tools

  section "Trivy Operator Pods"
  kubectl get pods -n "$TRIVY_NAMESPACE" -o wide || true

  local kind
  local found=0
  for kind in "${TRIVY_REPORT_KINDS[@]}"; do
    section "$kind"
    if kubectl get "$kind" -A -o wide; then
      found=1
    else
      printf 'No %s found, or this report kind is not installed by the current Trivy Operator chart.\n' "$kind"
    fi
  done

  if [[ "$found" == "0" ]]; then
    printf '\nNo Trivy report resources were found. Reports can take a few minutes to appear after workloads are created.\n'
  fi
}

kube_bench_report() {
  require_reports_tools

  section "kube-bench Job"
  kubectl get job kube-bench -n "$KUBE_BENCH_NAMESPACE" -o wide

  section "kube-bench Pods"
  kubectl get pods -n "$KUBE_BENCH_NAMESPACE" -l app.kubernetes.io/name=kube-bench -o wide

  section "kube-bench Logs"
  kubectl logs -n "$KUBE_BENCH_NAMESPACE" job/kube-bench
}

all_reports() {
  local failed=0

  falco_report || failed=1
  trivy_reports || failed=1
  kube_bench_report || failed=1

  return "$failed"
}

save_reports() {
  require_reports_tools

  local reports_root
  local report_dir
  local timestamp

  case "$REPORTS_DIR" in
    /*) reports_root="$REPORTS_DIR" ;;
    *) reports_root="${ROOT_DIR}/${REPORTS_DIR#./}" ;;
  esac
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  report_dir="${reports_root}/${timestamp}"
  mkdir -p "$report_dir"

  {
    printf 'CKS reports\n'
    printf 'Generated: %s\n' "$timestamp"
    printf 'Kubeconfig: %s\n' "$KUBECONFIG_PATH"
    printf 'Falco namespace: %s\n' "$FALCO_NAMESPACE"
    printf 'Trivy namespace: %s\n' "$TRIVY_NAMESPACE"
    printf 'kube-bench namespace: %s\n' "$KUBE_BENCH_NAMESPACE"
  } >"${report_dir}/summary.txt"

  falco_report >"${report_dir}/falco.log" 2>&1 || true
  trivy_reports >"${report_dir}/trivy.txt" 2>&1 || true
  kube_bench_report >"${report_dir}/kube-bench.log" 2>&1 || true

  log "Saved CKS reports to ${report_dir}"
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  all) all_reports ;;
  falco) falco_report ;;
  trivy) trivy_reports ;;
  kube-bench) kube_bench_report ;;
  save) save_reports ;;
  *) die "unknown report command: ${1:-}" ;;
esac
