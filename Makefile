SHELL := /bin/bash

CONFIG ?= config/cluster.env
ADDONS_CONFIG ?= config/addons.env
HARDENING_CONFIG ?= config/hardening.env

export CONFIG
export ADDONS_CONFIG
export HARDENING_CONFIG
export CLUSTER_NAME
export KUBERNETES_MINOR
export KUBERNETES_VERSION
export K8S_VERSION
export CONTROL_PLANES
export WORKERS
export CPUS
export MEMORY
export DISK
export MULTIPASS_LAUNCH_TIMEOUT
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
export REPORTS_DIR
export FALCO_LOG_LINES
export ENCRYPTION_PROVIDER
export ENCRYPTION_RESOURCES
export ENCRYPTION_CONFIG_PATH
export ENCRYPTION_KEY_NAME
export AUDIT_POLICY_SOURCE
export AUDIT_POLICY_PATH
export AUDIT_LOG_PATH
export AUDIT_LOG_MAXAGE
export AUDIT_LOG_MAXBACKUP
export AUDIT_LOG_MAXSIZE

.PHONY: help create start stop destroy status diagnose kubeconfig cilium apparmor cks-tools cks-clean cks-reports falco-report trivy-reports kube-bench-report cks-reports-save harden harden-audit harden-encryption-migrate check-tools verify

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

cks-reports:
	@./scripts/reports.sh all

falco-report:
	@./scripts/reports.sh falco

trivy-reports:
	@./scripts/reports.sh trivy

kube-bench-report:
	@./scripts/reports.sh kube-bench

cks-reports-save:
	@./scripts/reports.sh save

harden:
	@./scripts/hardening.sh harden

harden-audit:
	@./scripts/hardening.sh audit

harden-encryption-migrate:
	@./scripts/hardening.sh encryption-migrate

check-tools:
	@./scripts/cluster.sh check-tools

verify:
	@bash -n scripts/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi
