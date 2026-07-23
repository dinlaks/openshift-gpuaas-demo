#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Apply MIG partition profiles to GPU nodes based on their role.
#
# Reads NODE_ROLES and MIG_STRATEGY from env.sh (same logic as 01-node-labels.sh):
#   - Nodes listed in NODE_ROLES get their specific profile
#   - All other GPU nodes get the profile for MIG_STRATEGY (default: small)
#
# Node roles and the mig-parted profile they map to:
#   small       → all-1g.Xgb          (uniform small slices, all GPUs)
#   large       → all-Xg.Ygb          (uniform large slices, all GPUs)
#   dedicated   → no MIG config       (full GPU, mig-enabled: false via mig-parted)
#   mixed       → mixed-<gpu-type>    (GPU[0] small, GPU[1] small+large — 2 GPUs needed)
#   full-combo  → full-combo-<gpu>    (GPU[0] small MIG, GPU[1] full GPU — 2 GPUs needed)
#
# Override a single node's profile manually:
#   bash configure-mig.sh --node worker-gpu-0 --role mixed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
resolve_gpu_config

MIG_STRATEGY="${MIG_STRATEGY:-small}"
NODE_ROLES=("${NODE_ROLES[@]:-}")

# ── Optional single-node override via CLI args ─────────────────────────────────
OVERRIDE_NODE=""
OVERRIDE_ROLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) shift; OVERRIDE_NODE="${1:-}" ;;
    --role) shift; OVERRIDE_ROLE="${1:-}" ;;
    *) error "Unknown argument: $1. Usage: configure-mig.sh [--node <name> --role <role>]"; exit 1 ;;
  esac
  shift
done

require_oc_login

# Apply the mig-parted ConfigMap (profile library)
apply_cr "${SCRIPT_DIR}/mig-parted-config.yaml"

# ── Single-node override mode ──────────────────────────────────────────────────
if [[ -n "${OVERRIDE_NODE}" && -n "${OVERRIDE_ROLE}" ]]; then
  profile=$(get_profile_for_role "${OVERRIDE_ROLE}")
  if [[ -z "${profile}" ]]; then
    info "Role '${OVERRIDE_ROLE}' = dedicated (no MIG). Removing mig.config label from ${OVERRIDE_NODE}."
    oc label node "${OVERRIDE_NODE}" nvidia.com/mig.config- --overwrite 2>/dev/null || true
  else
    info "Applying profile '${profile}' to ${OVERRIDE_NODE} (role=${OVERRIDE_ROLE})"
    oc label node "${OVERRIDE_NODE}" "nvidia.com/mig.config=${profile}" --overwrite
  fi
  wait_for "MIG config applied on ${OVERRIDE_NODE}" \
    "oc get node ${OVERRIDE_NODE} -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' \
      2>/dev/null | grep -qi success" 300 15
  success "Done"
  exit 0
fi

# ── Multi-node mode (NODE_ROLES + MIG_STRATEGY) ────────────────────────────────
GPU_NODES=($(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's|node/||'))
if (( ${#GPU_NODES[@]} == 0 )); then
  error "No GPU nodes found. Check NFD and GPU Operator."
  exit 1
fi

# Build node→role lookup from NODE_ROLES
declare -A NODE_ROLE_MAP
for entry in "${NODE_ROLES[@]:-}"; do
  [[ -z "${entry}" ]] && continue
  node="${entry%%:*}"
  role="${entry##*:}"
  if ! oc get node "${node}" &>/dev/null; then
    warn "NODE_ROLES entry '${node}' not found in cluster — check the exact name with: oc get nodes"
    warn "Skipping '${node}:${role}' — MIG_STRATEGY default will apply to it instead"
    continue
  fi
  NODE_ROLE_MAP["${node}"]="${role}"
done

MIG_NODES=()   # nodes that need mig-manager to run

for NODE in "${GPU_NODES[@]}"; do
  if [[ -n "${NODE_ROLE_MAP[${NODE}]:-}" ]]; then
    role="${NODE_ROLE_MAP[${NODE}]}"
  else
    role="${MIG_STRATEGY}"
  fi

  profile=$(get_profile_for_role "${role}")

  if [[ -z "${profile}" ]]; then
    # dedicated — remove mig.config label so mig-manager disables MIG
    info "Node ${NODE}: role=dedicated — removing MIG config"
    oc label node "${NODE}" nvidia.com/mig.config- --overwrite 2>/dev/null || true
  else
    info "Node ${NODE}: role=${role} → profile=${profile}"
    oc label node "${NODE}" "nvidia.com/mig.config=${profile}" --overwrite
    MIG_NODES+=("${NODE}")
  fi
done

# Wait for mig-manager to apply partitions on all MIG nodes
if (( ${#MIG_NODES[@]} > 0 )); then
  info "MIG manager applying partitions on: ${MIG_NODES[*]}"
  info "Monitor: oc get pods -n nvidia-gpu-operator -l app=nvidia-mig-manager -w"
  wait_for "MIG config applied on all nodes" \
    "oc get nodes -l nvidia.com/mig.config.state=success --no-headers \
      | wc -l | xargs -I{} test {} -ge ${#MIG_NODES[@]}" \
    300 15
  success "MIG partitions active on ${#MIG_NODES[@]} node(s)"
fi

# Device plugin may have been waiting for MIG slices on a fresh install.
# Now that partitions are carved, wait for it to become ready.
wait_for "NVIDIA device plugin ready" \
  "oc get ds nvidia-device-plugin-daemonset -n nvidia-gpu-operator --no-headers 2>/dev/null \
    | awk '{print \$4}' | grep -v '^0\$'" 120 10 \
  || warn "Device plugin not yet ready — check: oc get ds -n nvidia-gpu-operator"

info "Verify: bash 02-gpu-setup/05-validation/validate-nodes.sh"
