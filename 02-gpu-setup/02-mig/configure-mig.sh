#!/usr/bin/env bash
# Apply MIG configuration to GPU nodes labelled demo/gpu-mode=mig-mixed.
# Nodes must have nvidia.com/gpu.present=true from NFD before running this.
#
# Usage:
#   bash configure-mig.sh <profile>
#   bash configure-mig.sh mixed-a30      # A30: 1x2g.12gb + 2x1g.6gb (default)
#   bash configure-mig.sh all-1g.6gb    # A30/A100: all smallest slices
#   bash configure-mig.sh all-2g.10gb   # A100: all medium slices
#
# Profile names are defined in the mig-parted-config ConfigMap.
# See: https://github.com/NVIDIA/mig-parted for available profiles per GPU.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
require_oc_login

MIG_PROFILE="${1:-${MIG_PROFILE:-mixed-a30}}"

header "Configuring MIG: profile=${MIG_PROFILE}"

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
