#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_cluster_config
load_addons_config

export KUBECONFIG="$KUBECONFIG_PATH"

usage() {
  cat <<'USAGE'
Add-ons for the Multipass Kubernetes lab

Usage:
  ./scripts/addons.sh cilium
  ./scripts/addons.sh apparmor
  ./scripts/addons.sh cks-tools
  ./scripts/addons.sh cks-clean
USAGE
}

install_cilium() {
  require_kubeconfig
  need_cmd kubectl

  if command -v cilium >/dev/null 2>&1; then
    log "Installing Cilium ${CILIUM_VERSION} with the Cilium CLI"
    local wait_arg=()
    if [[ "$CILIUM_WAIT" == "true" ]]; then
      wait_arg=(--wait)
    fi

    # shellcheck disable=SC2086
    cilium install \
      --namespace "$CILIUM_NAMESPACE" \
      --version "$CILIUM_VERSION" \
      "${wait_arg[@]}" \
      $CILIUM_EXTRA_ARGS

    if [[ "$CILIUM_WAIT" == "true" ]]; then
      cilium status --namespace "$CILIUM_NAMESPACE" --wait
    fi
    return
  fi

  need_cmd helm
  log "Cilium CLI not found; installing Cilium ${CILIUM_VERSION} with Helm"
  helm repo add cilium https://helm.cilium.io/ >/dev/null
  helm repo update cilium >/dev/null
  # shellcheck disable=SC2086
  helm upgrade --install cilium cilium/cilium \
    --namespace "$CILIUM_NAMESPACE" \
    --version "$CILIUM_VERSION" \
    --set ipam.mode=kubernetes \
    --wait \
    $CILIUM_HELM_EXTRA_ARGS
}

load_apparmor_profile() {
  require_cluster_instances
  require_kubeconfig
  need_cmd multipass
  need_cmd kubectl

  local profile="${ROOT_DIR}/${APPARMOR_PROFILE_PATH#./}"
  local manifest="${ROOT_DIR}/${APPARMOR_DEMO_MANIFEST#./}"
  [[ -f "$profile" ]] || die "AppArmor profile not found: $profile"
  [[ -f "$manifest" ]] || die "AppArmor demo manifest not found: $manifest"

  local node
  for node in $(all_nodes); do
    log "Loading AppArmor profile on $node"
    multipass transfer "$profile" "${node}:/tmp/${APPARMOR_PROFILE_NAME}"
    mp_exec "$node" sudo install -m 0644 "/tmp/${APPARMOR_PROFILE_NAME}" "/etc/apparmor.d/${APPARMOR_PROFILE_NAME}"
    mp_exec "$node" sudo apparmor_parser -r "/etc/apparmor.d/${APPARMOR_PROFILE_NAME}"
    kubectl label node "$node" "apparmor.local/${APPARMOR_PROFILE_NAME}=true" --overwrite
  done

  log "Applying AppArmor demo pod"
  kubectl apply -f "$manifest"
}

install_cks_tools() {
  require_kubeconfig
  need_cmd kubectl
  need_cmd helm

  log "Installing Falco"
  helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null
  helm repo update falcosecurity >/dev/null
  # shellcheck disable=SC2086
  helm upgrade --install falco falcosecurity/falco \
    --namespace "$FALCO_NAMESPACE" \
    --create-namespace \
    --wait \
    $FALCO_HELM_EXTRA_ARGS

  log "Installing Trivy Operator"
  helm repo add aqua https://aquasecurity.github.io/helm-charts/ >/dev/null
  helm repo update aqua >/dev/null
  local trivy_values="${ROOT_DIR}/${TRIVY_VALUES_FILE#./}"
  [[ -f "$trivy_values" ]] || die "Trivy values file not found: $trivy_values"
  # shellcheck disable=SC2086
  helm upgrade --install trivy-operator aqua/trivy-operator \
    --namespace "$TRIVY_NAMESPACE" \
    --create-namespace \
    --values "$trivy_values" \
    --wait \
    $TRIVY_HELM_EXTRA_ARGS

  log "Creating kube-bench job"
  kubectl create namespace "$KUBE_BENCH_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: ${KUBE_BENCH_NAMESPACE}
  labels:
    app.kubernetes.io/name: kube-bench
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
    spec:
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: ${KUBE_BENCH_IMAGE}
          command: ["kube-bench"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: usr-bin
          hostPath:
            path: /usr/bin
EOF
}

clean_cks_tools() {
  require_kubeconfig
  need_cmd kubectl

  if command -v helm >/dev/null 2>&1; then
    helm uninstall falco -n "$FALCO_NAMESPACE" >/dev/null 2>&1 || true
    helm uninstall trivy-operator -n "$TRIVY_NAMESPACE" >/dev/null 2>&1 || true
  fi

  kubectl delete job kube-bench -n "$KUBE_BENCH_NAMESPACE" --ignore-not-found
  kubectl delete namespace "$KUBE_BENCH_NAMESPACE" --ignore-not-found
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  cilium) install_cilium ;;
  apparmor) load_apparmor_profile ;;
  cks-tools) install_cks_tools ;;
  cks-clean) clean_cks_tools ;;
  *) die "unknown command: ${1:-}" ;;
esac
