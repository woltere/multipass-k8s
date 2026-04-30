# Multipass Kubernetes Lab

Small kubeadm-based Kubernetes clusters on macOS with Multipass.

The cluster is intentionally bootstrapped without a CNI so that Cilium can be installed as a separate step. AppArmor profiles and common CKS practice tools are also separate, repeatable commands.

## Requirements

- macOS with Multipass installed
- `kubectl` for local cluster access
- `helm` for CKS add-ons
- `cilium` CLI for the Cilium target, or Helm as a fallback

Check local tools:

```sh
make check-tools
```

## Quick Start

```sh
make create
make cilium
export KUBECONFIG="$PWD/.state/kubeconfig"
kubectl get nodes
```

The default cluster is one control plane and two workers. Override settings from the command line:

```sh
make create KUBERNETES_MINOR=1.35 KUBERNETES_VERSION=latest CONTROL_PLANES=1 WORKERS=3
```

For an exact Kubernetes patch release:

```sh
make create KUBERNETES_MINOR=1.35 KUBERNETES_VERSION=1.35.0
```

The scripts use the Kubernetes community package repositories at `pkgs.k8s.io`; `KUBERNETES_MINOR` selects the apt repository and `KUBERNETES_VERSION` selects either `latest` within that minor or an exact package version.

## Commands

```sh
make create       # launch VMs and run kubeadm
make start        # start stopped Multipass instances
make stop         # stop Multipass instances
make destroy      # delete and purge cluster instances
make status       # show Multipass and Kubernetes status
make diagnose     # show first control-plane bootstrap and kubelet diagnostics
make kubeconfig   # refresh .state/kubeconfig from the first control plane
make cilium       # install Cilium
make apparmor     # load AppArmor profile on every node and apply a demo pod
make cks-tools    # install Falco, Trivy Operator, and a kube-bench job
make cks-clean    # remove the CKS add-ons installed by this project
```

## Configuration

Main cluster defaults live in `config/cluster.env`.

Add-on defaults live in `config/addons.env`.

Trivy Operator Helm values live in `config/trivy-operator-values.yaml`, including control-plane tolerations for scan jobs and the node collector.

Every setting can be overridden through the environment or `make` variables, for example:

```sh
make create CLUSTER_NAME=cks-lab CPUS=4 MEMORY=6G DISK=30G WORKERS=2
make cilium CILIUM_VERSION=1.19.3
```

## CKS Add-ons

The `cks-tools` target installs practical tools commonly used while studying the CKS domains:

- Falco for runtime security monitoring
- Trivy Operator for vulnerability and configuration scanning
- kube-bench as a Kubernetes CIS benchmark job

These are intentionally add-ons, not part of cluster bootstrap, so the base cluster remains close to a raw kubeadm lab.

## AppArmor

`make apparmor` loads `profiles/apparmor/k8s-deny-write` on every Multipass node with `apparmor_parser`, labels the nodes, and applies `k8s/apparmor/deny-write-demo.yaml`.

Verify it:

```sh
export KUBECONFIG="$PWD/.state/kubeconfig"
kubectl exec hello-apparmor -- cat /proc/1/attr/current
kubectl exec hello-apparmor -- touch /tmp/test
```

The second command should fail because the demo profile denies file writes.

## Notes

- Multiple control planes are supported for kubeadm practice, but this scaffold does not add a load balancer by default. The first control plane is used as the API endpoint unless `CONTROL_PLANE_ENDPOINT` is set.
- Deleting the cluster runs `multipass delete --purge` for instances named with `CLUSTER_NAME` and removes the project-local `.state` directory.
- Most add-on commands require internet access from the macOS host and the Multipass instances.

## Troubleshooting

Seeing kubelet restart with `failed to load kubelet config file, path: /var/lib/kubelet/config.yaml` is expected before `kubeadm init` completes. The kubelet package starts early and waits for kubeadm to write `/var/lib/kubelet/config.yaml` and `/var/lib/kubelet/kubeadm-flags.env`.

Seeing kubelet repeat `NetworkPluginNotReady` and `cni plugin not initialized` after `make create` is also expected until a CNI is installed. Run `make cilium`; the nodes should become `Ready` after Cilium finishes rolling out.

If that message continues after `make create` exits with an error, run:

```sh
make diagnose
```

The useful distinction is whether `/etc/kubernetes/admin.conf` and `/var/lib/kubelet/config.yaml` exist on the first control-plane node. If they do not, kubeadm init did not complete; check the cloud-init output and containerd status in the diagnostic output.

For kubeadm stacked etcd, the API server normally has `--etcd-servers=https://127.0.0.1:2379`. The API server and etcd static pods both use the control-plane node network namespace, so localhost is the VM itself. If API server logs repeatedly show connection failures to `127.0.0.1:2379`, inspect the etcd container logs from `make diagnose`; the usual cause is that the local etcd static pod is not running or is crashlooping.

Older Cilium CLI versions do not support `cilium install --kubeconfig`; this project exports `KUBECONFIG` before invoking `cilium`. If Cilium install still fails, check `cilium version --client` and consider upgrading the CLI or using the Helm fallback.
