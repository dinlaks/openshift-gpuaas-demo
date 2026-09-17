#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Enable DCGM pod-level GPU metric attribution for the RHOAI 3.5 Infrastructure dashboard.
#
# By default the GPU Operator deploys the DCGM exporter with automountServiceAccountToken=false,
# preventing it from calling the Kubernetes API to map GPU devices to pods. Without this mapping,
# the RHOAI Infrastructure dashboard cannot show per-queue compute/memory consumption.
#
# This script:
#   1. Grants the nvidia-dcgm-exporter SA cluster-wide pod read access
#   2. Enables service account token mounting on the DCGM exporter DaemonSet
#
# Run once after GPU Operator is installed. GPU Operator may revert the DaemonSet
# patch on reconciliation — re-run this script if pod attribution stops working.
#
# Usage:
#   bash 02-gpu-setup/06-dcgm-pod-attribution.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_env
require_oc_login

header "DCGM pod attribution for RHOAI Infrastructure dashboard"

info "Creating ClusterRoleBinding for DCGM pod discovery..."
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nvidia-dcgm-exporter-pod-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: nvidia-dcgm-exporter
    namespace: nvidia-gpu-operator
EOF

info "Enabling service account token on DCGM exporter DaemonSet..."
oc patch daemonset nvidia-dcgm-exporter -n nvidia-gpu-operator \
  --type=merge \
  -p '{"spec":{"template":{"spec":{"automountServiceAccountToken":true}}}}'

info "Waiting for DCGM exporter rollout..."
oc rollout status daemonset/nvidia-dcgm-exporter -n nvidia-gpu-operator --timeout=120s

success "DCGM pod attribution enabled"
info "Verify: oc logs -n nvidia-gpu-operator -l app=nvidia-dcgm-exporter | grep -i 'pod inform'"
info "Metrics will appear in Prometheus within ~60s after pods with GPU workloads are running."
