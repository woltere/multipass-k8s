#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_cluster_config

usage() {
  cat <<'USAGE'
Multipass Kubernetes lab

Usage:
  make create [KUBERNETES_MINOR=1.35] [KUBERNETES_VERSION=latest] [CONTROL_PLANES=1] [WORKERS=2]
  make start
  make stop
  make destroy
  make status
  make diagnose
  make kubeconfig
  make cilium
  make apparmor
  make cks-tools
  make cks-clean
  make cks-reports
  make falco-report
  make trivy-reports
  make kube-bench-report
  make cks-reports-save

Direct script usage:
  ./scripts/cluster.sh <create|start|stop|destroy|status|diagnose|kubeconfig|check-tools>
USAGE
}

cloud_init_file() {
  local path="$1"
  cat >"$path" <<EOF
#cloud-config
package_update: true
package_upgrade: true
write_files:
  - path: /usr/local/sbin/bootstrap-k8s-node.sh
    permissions: "0o755"
    content: |
      #!/usr/bin/env bash
      set -euxo pipefail

      KUBERNETES_MINOR="${KUBERNETES_MINOR}"
      KUBERNETES_VERSION="${KUBERNETES_VERSION#v}"

      swapoff -a
      sed -i.bak '/ swap / s/^/#/' /etc/fstab

      cat >/etc/modules-load.d/kubernetes.conf <<'MODULES'
      overlay
      br_netfilter
      MODULES

      modprobe overlay
      modprobe br_netfilter

      cat >/etc/sysctl.d/99-kubernetes.conf <<'SYSCTL'
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
      SYSCTL

      sysctl --system

      install -m 0755 -d /etc/apt/keyrings
      apt-get update
      apt-get install -y apt-transport-https ca-certificates curl gpg jq apparmor apparmor-utils auditd

      . /etc/os-release
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \${VERSION_CODENAME} stable" \
        >/etc/apt/sources.list.d/docker.list

      curl -fsSL "https://pkgs.k8s.io/core:/stable:/v\${KUBERNETES_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v\${KUBERNETES_MINOR}/deb/ /" \
        >/etc/apt/sources.list.d/kubernetes.list

      apt-get update
      apt-get install -y containerd.io
      mkdir -p /etc/containerd
      containerd config default >/etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      cat >/etc/crictl.yaml <<'CRICTL'
      runtime-endpoint: unix:///run/containerd/containerd.sock
      image-endpoint: unix:///run/containerd/containerd.sock
      timeout: 10
      debug: false
      CRICTL
      systemctl restart containerd
      systemctl enable containerd

      if [[ "\${KUBERNETES_VERSION}" == "latest" ]]; then
        apt-get install -y kubelet kubeadm kubectl
      else
        KUBE_PACKAGE_VERSION="\$(apt-cache madison kubelet | awk -v version="\${KUBERNETES_VERSION}-" '\$3 ~ "^" version { print \$3; exit }')"
        if [[ -z "\${KUBE_PACKAGE_VERSION}" ]]; then
          echo "Kubernetes package version \${KUBERNETES_VERSION} was not found in v\${KUBERNETES_MINOR}" >&2
          apt-cache madison kubelet >&2
          exit 1
        fi
        apt-get install -y "kubelet=\${KUBE_PACKAGE_VERSION}" "kubeadm=\${KUBE_PACKAGE_VERSION}" "kubectl=\${KUBE_PACKAGE_VERSION}"
      fi

      apt-mark hold kubelet kubeadm kubectl
      # kubelet crashloops until kubeadm writes /var/lib/kubelet/config.yaml.
      systemctl enable --now kubelet
      systemctl enable --now apparmor
      systemctl enable --now auditd
runcmd:
  - /usr/local/sbin/bootstrap-k8s-node.sh
EOF
}

launch_node() {
  local node="$1"
  local cloud_init="$2"

  if instance_exists "$node"; then
    log "Using existing instance $node"
    return
  fi

  log "Launching $node"
  multipass launch "$IMAGE" \
    --name "$node" \
    --cpus "$CPUS" \
    --memory "$MEMORY" \
    --disk "$DISK" \
    --timeout "$MULTIPASS_LAUNCH_TIMEOUT" \
    --cloud-init "$cloud_init"
}

wait_cloud_init() {
  local node="$1"
  log "Waiting for cloud-init on $node"
  wait_node_exec "$node"
  mp_exec "$node" cloud-init status --wait
}

wait_node_exec() {
  local node="$1"
  local attempt
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if mp_exec "$node" true >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done

  log "Restarting $node because multipass exec did not become available"
  multipass restart "$node"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if mp_exec "$node" true >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done

  die "timed out waiting for $node to accept multipass exec"
}

restart_nodes_if_required() {
  local node
  for node in $(all_nodes); do
    if mp_exec "$node" test -f /var/run/reboot-required; then
      log "Restarting $node after package upgrades"
      multipass restart "$node"
      wait_node_exec "$node"
      wait_cloud_init "$node"
    else
      log "No restart required for $node"
    fi
  done
}

bootstrap_control_plane() {
  local first_cp
  local first_cp_ip
  local endpoint
  local kubeadm_version

  first_cp="$(node_name cp 1)"
  first_cp_ip="$(node_ip "$first_cp")"
  endpoint="${CONTROL_PLANE_ENDPOINT:-${first_cp_ip}:6443}"
  if [[ "$endpoint" != *:* ]]; then
    endpoint="${endpoint}:6443"
  fi
  kubeadm_version="$(mp_exec "$first_cp" kubeadm version -o short)"

  if mp_exec "$first_cp" test -f /etc/kubernetes/admin.conf; then
    log "Control plane already initialized on $first_cp"
    return
  fi

  log "Initializing control plane on $first_cp with Kubernetes ${kubeadm_version}"
  mp_exec "$first_cp" sudo kubeadm init \
    --kubernetes-version "$kubeadm_version" \
    --apiserver-advertise-address "$first_cp_ip" \
    --control-plane-endpoint "$endpoint" \
    --pod-network-cidr "$POD_CIDR" \
    --service-cidr "$SERVICE_CIDR" \
    --upload-certs

  if [[ "$WORKERS" == "0" ]]; then
    mp_exec "$first_cp" sudo kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- || true
  fi
}

join_control_planes() {
  local first_cp
  local cert_key
  local join_command
  local i
  local node

  if (( CONTROL_PLANES <= 1 )); then
    return
  fi

  first_cp="$(node_name cp 1)"
  cert_key="$(mp_exec "$first_cp" sudo kubeadm init phase upload-certs --upload-certs | tail -n 1)"
  join_command="$(mp_exec "$first_cp" sudo kubeadm token create --print-join-command)"

  for ((i = 2; i <= CONTROL_PLANES; i++)); do
    node="$(node_name cp "$i")"
    if mp_exec "$node" test -f /etc/kubernetes/admin.conf; then
      log "Control plane already joined: $node"
      continue
    fi

    log "Joining control plane $node"
    mp_exec "$node" sudo bash -lc "${join_command} --control-plane --certificate-key ${cert_key}"
  done
}

join_workers() {
  local first_cp
  local join_command
  local i
  local node

  if (( WORKERS <= 0 )); then
    return
  fi

  first_cp="$(node_name cp 1)"
  join_command="$(mp_exec "$first_cp" sudo kubeadm token create --print-join-command)"

  for ((i = 1; i <= WORKERS; i++)); do
    node="$(node_name worker "$i")"
    if mp_exec "$node" test -f /etc/kubernetes/kubelet.conf; then
      log "Worker already joined: $node"
      continue
    fi

    log "Joining worker $node"
    mp_exec "$node" sudo bash -lc "$join_command"
  done
}

write_kubeconfig() {
  local first_cp
  first_cp="$(node_name cp 1)"
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  log "Writing kubeconfig to $KUBECONFIG_PATH"
  mp_exec "$first_cp" sudo cat /etc/kubernetes/admin.conf >"$KUBECONFIG_PATH"
  chmod 0600 "$KUBECONFIG_PATH"
}

create_cluster() {
  need_cmd multipass

  mkdir -p "$STATE_DIR"
  local cloud_init
  cloud_init="$(mktemp "${STATE_DIR}/cloud-init.XXXXXX.yaml")"
  cloud_init_file "$cloud_init"

  local node
  for node in $(all_nodes); do
    launch_node "$node" "$cloud_init"
  done

  for node in $(all_nodes); do
    wait_cloud_init "$node"
  done

  restart_nodes_if_required
  bootstrap_control_plane
  join_control_planes
  join_workers
  write_kubeconfig

  log "Cluster created. Next: make cilium"
}

start_cluster() {
  need_cmd multipass
  local node
  for node in $(cluster_instances); do
    if instance_exists "$node"; then
      log "Starting $node"
      multipass start "$node"
    fi
  done
}

stop_cluster() {
  need_cmd multipass
  local node
  for node in $(cluster_instances); do
    if instance_exists "$node"; then
      log "Stopping $node"
      multipass stop "$node"
    fi
  done
}

destroy_cluster() {
  need_cmd multipass
  local node
  for node in $(cluster_instances); do
    if instance_exists "$node"; then
      log "Deleting $node"
      multipass delete --purge "$node"
    fi
  done
  remove_state_dir
  log "Cluster instances removed"
}

remove_state_dir() {
  case "$STATE_DIR" in
    "$ROOT_DIR"/*)
      if [[ -d "$STATE_DIR" ]]; then
        log "Removing state directory $STATE_DIR"
        rm -rf "$STATE_DIR"
      fi
      ;;
    *)
      log "Leaving state directory outside project untouched: $STATE_DIR"
      ;;
  esac
}

status_cluster() {
  need_cmd multipass
  local node
  for node in $(cluster_instances); do
    if instance_exists "$node"; then
      multipass info "$node"
    else
      printf '%s: not created\n' "$node"
    fi
  done

  if [[ -f "$KUBECONFIG_PATH" ]] && command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes -o wide || true
  fi
}

diagnose_cluster() {
  need_cmd multipass

  local first_cp
  first_cp="$(node_name cp 1)"
  instance_exists "$first_cp" || die "Multipass instance does not exist: $first_cp"

  log "cloud-init status"
  mp_exec "$first_cp" cloud-init status --long || true

  log "kubeadm/kubelet files"
  mp_exec "$first_cp" sudo bash -lc 'ls -l /etc/kubernetes/admin.conf /var/lib/kubelet/config.yaml /var/lib/kubelet/kubeadm-flags.env 2>/dev/null || true'

  log "containerd status"
  mp_exec "$first_cp" sudo systemctl --no-pager --full status containerd || true

  log "control-plane static manifests"
  mp_exec "$first_cp" sudo bash -lc 'ls -l /etc/kubernetes/manifests && grep -R --line-number -- "--etcd-servers\\|listen-client-urls\\|advertise-client-urls" /etc/kubernetes/manifests 2>/dev/null || true'

  log "local etcd listener"
  mp_exec "$first_cp" sudo ss -ltnp 'sport = :2379' || true

  log "container runtime pods"
  mp_exec "$first_cp" sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods || true

  log "control-plane containers"
  mp_exec "$first_cp" sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a --name 'kube-apiserver|etcd|kube-controller-manager|kube-scheduler' || true

  log "recent etcd container logs"
  # shellcheck disable=SC2016
  mp_exec "$first_cp" sudo bash -lc 'id="$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a --name etcd -q | head -n 1)"; if [[ -n "$id" ]]; then crictl --runtime-endpoint unix:///run/containerd/containerd.sock logs --tail=120 "$id"; else echo "no etcd container found"; fi' || true

  log "recent apiserver container logs"
  # shellcheck disable=SC2016
  mp_exec "$first_cp" sudo bash -lc 'id="$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a --name kube-apiserver -q | head -n 1)"; if [[ -n "$id" ]]; then crictl --runtime-endpoint unix:///run/containerd/containerd.sock logs --tail=120 "$id"; else echo "no kube-apiserver container found"; fi' || true

  log "kubelet status"
  mp_exec "$first_cp" sudo systemctl --no-pager --full status kubelet || true

  log "recent kubelet logs"
  mp_exec "$first_cp" sudo journalctl -u kubelet -n 80 --no-pager || true

  log "recent cloud-init logs"
  mp_exec "$first_cp" sudo tail -n 120 /var/log/cloud-init-output.log || true
}

check_tools() {
  maybe_cmd multipass
  maybe_cmd kubectl
  maybe_cmd helm
  maybe_cmd cilium
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  create) create_cluster ;;
  start) start_cluster ;;
  stop) stop_cluster ;;
  destroy) destroy_cluster ;;
  status) status_cluster ;;
  diagnose) diagnose_cluster ;;
  kubeconfig) need_cmd multipass; write_kubeconfig ;;
  check-tools) check_tools ;;
  *) die "unknown command: ${1:-}" ;;
esac
