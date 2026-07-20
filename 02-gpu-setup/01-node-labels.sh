#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Label GPU nodes with capability labels for Kueue ResourceFlavor matching.
#
# Two modes — set one in env.sh:
#
#   Simple (MIG_STRATEGY):  same role applied to ALL GPU nodes
#     MIG_STRATEGY=small       all nodes: small MIG slices only
#     MIG_STRATEGY=large       all nodes: large MIG slices only
#     MIG_STRATEGY=dedicated   all nodes: full GPU, no MIG
#     MIG_STRATEGY=mixed       all nodes: small+large MIG (2+ GPUs per node)
#     MIG_STRATEGY=full-combo  all nodes: small MIG + full GPU (2+ GPUs per node)
#
#   Per-node (NODE_ROLES):  specific role per node + MIG_STRATEGY as default
#     NODE_ROLES=(
#       "worker-gpu-0:small"
#       "worker-gpu-1:dedicated"
#       "worker-gpu-2:mixed"
#     )
#     GPU nodes NOT listed in NODE_ROLES get MIG_STRATEGY (default: small).
#
# Capability labels set on each node:
#   demo/gpu-type=<GPU_TYPE>         e.g. h100-80gb
#   demo/gpu-memory=<GPU_MEMORY>     e.g. 80gb
#   demo/gpu-arch=<GPU_ARCH>         e.g. hopper
#   demo/gpu-role=<role>             e.g. mixed
#   demo/gpu-has-small-mig=true      set when role provides small MIG slices
#   demo/gpu-has-large-mig=true      set when role provides large MIG slices
#   demo/gpu-has-full=true           set when role provides a full non-MIG GPU
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_env
resolve_gpu_config

MIG_STRATEGY="${MIG_STRATEGY:-small}"
NODE_ROLES=("${NODE_ROLES[@]:-}")

GPU_NODES=($(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's|node/||'))
if (( ${#GPU_NODES[@]} == 0 )); then
  error "No GPU nodes found (nvidia.com/gpu.present=true). Check NFD and GPU Operator."
  exit 1
fi
info "Found ${#GPU_NODES[@]} GPU node(s): ${GPU_NODES[*]}"

require_oc_login

# Build a lookup of node→role from NODE_ROLES array
declare -A NODE_ROLE_MAP
for entry in "${NODE_ROLES[@]:-}"; do
  [[ -z "${entry}" ]] && continue
  node="${entry%%:*}"
  role="${entry##*:}"
  # Validate: warn if the node name in NODE_ROLES doesn't exist in the cluster
  if ! oc get node "${node}" &>/dev/null; then
    warn "NODE_ROLES entry '${node}' not found in cluster — check the exact name with: oc get nodes"
    warn "Skipping '${node}:${role}' — it will not be configured"
    continue
  fi
  NODE_ROLE_MAP["${node}"]="${role}"
done

# Apply labels to each GPU node
for NODE in "${GPU_NODES[@]}"; do
  if [[ -n "${NODE_ROLE_MAP[${NODE}]:-}" ]]; then
    role="${NODE_ROLE_MAP[${NODE}]}"
    info "Node ${NODE}: role=${role} (from NODE_ROLES)"
  else
    role="${MIG_STRATEGY}"
    info "Node ${NODE}: role=${role} (from MIG_STRATEGY default)"
  fi
  label_node_capabilities "${NODE}" "${role}"
done

success "All GPU nodes labelled"
info "Verify: bash 02-gpu-setup/05-validation/validate-nodes.sh"
