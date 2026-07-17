#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Apply MIG configuration to GPU nodes labelled demo/gpu-mode=mig-mixed.
# Nodes must have nvidia.com/gpu.present=true from NFD before running this.
#
# Usage:
#   bash configure-mig.sh               # uses MIG_PROFILE default for GPU_TYPE in env.sh
#   bash configure-mig.sh <profile>     # override with a specific profile name
#
# Profile names must exist in 02-mig/mig-parted-config.yaml.
# GPU_TYPE in env.sh determines the default profile automatically:
#   a30       → mixed-a30      a100-40gb → all-1g.5gb
#   a100-80gb → all-1g.10gb   h100-80gb → all-1g.10gb
#   h100-nvl  → all-1g.12gb   h200      → all-1g.18gb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
resolve_gpu_config   # sets MIG_PROFILE default from GPU_TYPE in env.sh
require_oc_login

# $1 overrides the env.sh/GPU_TYPE default if explicitly passed
MIG_PROFILE="${1:-${MIG_PROFILE}}"

header "Configuring MIG: GPU_TYPE=${GPU_TYPE}, profile=${MIG_PROFILE}"

apply_cr "${SCRIPT_DIR}/mig-parted-config.yaml"

GPU_NODES=$(oc get nodes -l demo/gpu-mode=mig-mixed -o name 2>/dev/null | sed 's|node/||' || true)
if [[ -z "${GPU_NODES}" ]]; then
  warn "No nodes with demo/gpu-mode=mig-mixed found."
  info "Run 01-node-labels.sh first, or label a node manually:"
  echo "  oc label node <node-name> demo/gpu-mode=mig-mixed demo/gpu-type=${GPU_TYPE:-a30}"
  exit 1
fi

for NODE in ${GPU_NODES}; do
  info "Setting MIG config on ${NODE} → ${MIG_PROFILE}"
  oc label node "${NODE}" \
    "nvidia.com/mig.config=${MIG_PROFILE}" \
    --overwrite
  success "Labelled ${NODE}"
done

info "MIG manager will now apply partitions. Watch progress:"
echo "  oc get pods -n nvidia-gpu-operator -l app=nvidia-mig-manager -w"
echo "  oc logs -n nvidia-gpu-operator -l app=nvidia-mig-manager -f"

wait_for "MIG config applied on all nodes" \
  "oc get nodes -l nvidia.com/mig.config.state=success --no-headers | grep -q ." \
  300 15

success "MIG partitions active!"
info "Verify MIG devices:"
echo "  oc get nodes -l demo/gpu-mode=mig-mixed -o json | jq '.items[].status.capacity | with_entries(select(.key | startswith(\"nvidia.com/mig\")))'"
