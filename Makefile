SHELL := /bin/bash

CONFIG ?= config/cluster.env
ADDONS_CONFIG ?= config/addons.env

export CONFIG
export ADDONS_CONFIG
export CLUSTER_NAME
export KUBERNETES_MINOR
export KUBERNETES_VERSION
export K8S_VERSION
export CONTROL_PLANES
export WORKERS
export CPUS
export MEMORY
export DISK
export IMAGE
export POD_CIDR
export SERVICE_CIDR
export CONTROL_PLANE_ENDPOINT
export STATE_DIR
export KUBECONFIG_PATH
export CILIUM_VERSION
export CILIUM_NAMESPACE
export CILIUM_WAIT
export CILIUM_EXTRA_ARGS
export CILIUM_HELM_EXTRA_ARGS
export APPARMOR_PROFILE_NAME
export APPARMOR_PROFILE_PATH
export APPARMOR_DEMO_MANIFEST
export FALCO_NAMESPACE
export FALCO_HELM_EXTRA_ARGS
export TRIVY_NAMESPACE
export TRIVY_VALUES_FILE
export TRIVY_HELM_EXTRA_ARGS
export KUBE_BENCH_NAMESPACE
export KUBE_BENCH_IMAGE

.PHONY: help create start stop destroy status diagnose kubeconfig cilium apparmor cks-tools cks-clean check-tools verify

help:
	@./scripts/cluster.sh help

create:
	@./scripts/cluster.sh create

start:
	@./scripts/cluster.sh start

stop:
	@./scripts/cluster.sh stop

destroy:
	@./scripts/cluster.sh destroy

status:
	@./scripts/cluster.sh status

diagnose:
	@./scripts/cluster.sh diagnose

kubeconfig:
	@./scripts/cluster.sh kubeconfig

cilium:
	@./scripts/addons.sh cilium

apparmor:
	@./scripts/addons.sh apparmor

cks-tools:
	@./scripts/addons.sh cks-tools

cks-clean:
	@./scripts/addons.sh cks-clean

check-tools:
	@./scripts/cluster.sh check-tools

verify:
	@bash -n scripts/*.sh
