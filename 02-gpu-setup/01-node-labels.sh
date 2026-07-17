#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Label GPU nodes for Kueue ResourceFlavor matching and MIG configuration.
#
# Uses GPU_TYPE and MIG_STRATEGY from env.sh to set the correct node labels.
# Nodes are discovered automatically via nvidia.com/gpu.present=true (set by NFD).
#
# Labels applied:
#   demo/gpu-type=<GPU_TYPE>        — e.g. a30, a100, h100
#   demo/gpu-mode=mig-mixed         — indicates MIG is active
#   demo/gpu-gpu0-mode=mig-1g6gb    — primary MIG partition (smaller slices)
#   demo/gpu-gpu1-mode=<full|mig-mixed>  — secondary GPU mode
#   nvidia.com/mig.config=<MIG_PROFILE>  — triggers nvidia-mig-manager
#
# Usage:
#   bash 01-node-labels.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_env
resolve_gpu_config   # sets MIG_PROFILE default and exports GPU_TYPE

MIG_ENABLED="${MIG_ENABLED:-true}"
MIG_STRATEGY="${MIG_STRATEGY:-mixed}"

GPU_NODES=($(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's|node/||'))
NODE_COUNT=${#GPU_NODES[@]}

if (( NODE_COUNT == 0 )); then
  error "No GPU nodes found (nvidia.com/gpu.present=true). Check NFD and GPU Operator."
  exit 1
fi

info "Found ${NODE_COUNT} GPU node(s): ${GPU_NODES[*]}"
info "GPU_TYPE=${GPU_TYPE}, MIG_ENABLED=${MIG_ENABLED}, MIG_STRATEGY=${MIG_STRATEGY}"

for NODE in "${GPU_NODES[@]}"; do
  if [[ "${MIG_ENABLED}" == "true" ]]; then
    oc label node "${NODE}" \
      "demo/gpu-type=${GPU_TYPE}" \
      "demo/gpu-mode=mig-${MIG_STRATEGY}" \
      "demo/gpu-gpu0-mode=mig-1g6gb" \
      "demo/gpu-gpu1-mode=mig-${MIG_STRATEGY}" \
      "nvidia.com/mig.config=${MIG_PROFILE}" \
      --overwrite
    success "Labelled ${NODE} (MIG ${MIG_STRATEGY}, profile=${MIG_PROFILE})"
  else
    oc label node "${NODE}" \
      "demo/gpu-type=${GPU_TYPE}" \
      "demo/gpu-mode=full" \
      --overwrite
    success "Labelled ${NODE} (full GPU mode)"
  fi
done

if [[ "${MIG_ENABLED}" == "true" ]]; then
  info "MIG manager will now partition GPUs. Monitor:"
  echo "  oc get pods -n nvidia-gpu-operator -l app=nvidia-mig-manager -w"
  wait_for "MIG config applied" \
    "oc get nodes -l nvidia.com/mig.config.state=success --no-headers | grep -q ." \
    300 15
fi

success "GPU nodes labelled"
