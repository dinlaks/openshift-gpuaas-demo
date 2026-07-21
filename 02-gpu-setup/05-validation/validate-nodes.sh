#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Inspect GPU node labels — shows both our demo/gpu-* labels and the
# nvidia.com/gpu.* labels set automatically by NFD + GPU Operator.
#
# Usage:
#   bash validate-nodes.sh          # show all GPU nodes
#   bash validate-nodes.sh --wide   # include MIG config state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
require_oc_login

WIDE=false
[[ "${1:-}" == "--wide" ]] && WIDE=true

GPU_NODES=($(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's|node/||'))

if (( ${#GPU_NODES[@]} == 0 )); then
  error "No GPU nodes found (nvidia.com/gpu.present=true). Check NFD and GPU Operator."
  exit 1
fi

header "GPU Node Inventory — ${#GPU_NODES[@]} node(s) found"

# ── Summary table ─────────────────────────────────────────────────────────────
echo ""
printf "%-45s %-12s %-8s %-8s %-10s %-10s %-10s\n" \
  "NODE" "GPU-TYPE" "MEMORY" "ARCH" "HAS-SMALL" "HAS-LARGE" "HAS-FULL"
printf "%-45s %-12s %-8s %-8s %-10s %-10s %-10s\n" \
  "----" "--------" "------" "----" "---------" "---------" "--------"

for NODE in "${GPU_NODES[@]}"; do
  # Bracket notation required for labels containing '/' — dot notation breaks JSONPath
  gpu_type=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-type"]}' 2>/dev/null || echo "-")
  gpu_mem=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-memory"]}' 2>/dev/null || echo "-")
  gpu_arch=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-arch"]}' 2>/dev/null || echo "-")
  has_small=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-has-small-mig"]}' 2>/dev/null || echo "-")
  has_large=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-has-large-mig"]}' 2>/dev/null || echo "-")
  has_full=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["demo/gpu-has-full"]}' 2>/dev/null || echo "-")

  [[ "${has_small}" == "true" ]] && has_small="✓" || has_small="-"
  [[ "${has_large}" == "true" ]] && has_large="✓" || has_large="-"
  [[ "${has_full}"  == "true" ]] && has_full="✓"  || has_full="-"

  printf "%-45s %-12s %-8s %-8s %-10s %-10s %-10s\n" \
    "${NODE}" "${gpu_type}" "${gpu_mem}" "${gpu_arch}" \
    "${has_small}" "${has_large}" "${has_full}"
done

# ── NFD hardware details ───────────────────────────────────────────────────────
echo ""
header "Hardware detail (from NFD + GPU Operator)"

printf "%-45s %-40s %-8s %-6s\n" "NODE" "GPU-PRODUCT" "MEM(MiB)" "COUNT"
printf "%-45s %-40s %-8s %-6s\n" "----" "-----------" "--------" "-----"

for NODE in "${GPU_NODES[@]}"; do
  product=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["nvidia.com/gpu.product"]}' 2>/dev/null || echo "-")
  mem=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["nvidia.com/gpu.memory"]}' 2>/dev/null || echo "-")
  count=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["nvidia.com/gpu.count"]}' 2>/dev/null || echo "-")
  printf "%-45s %-40s %-8s %-6s\n" "${NODE}" "${product}" "${mem}" "${count}"
done

# ── MIG config state (--wide only) ───────────────────────────────────────────
if [[ "${WIDE}" == "true" ]]; then
  echo ""
  header "MIG config state (nvidia-mig-manager)"

  printf "%-45s %-25s %-12s\n" "NODE" "MIG-PROFILE" "STATE"
  printf "%-45s %-25s %-12s\n" "----" "-----------" "-----"

  for NODE in "${GPU_NODES[@]}"; do
    profile=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["nvidia.com/mig.config"]}' 2>/dev/null || echo "-")
    state=$(oc get node "${NODE}" -o jsonpath='{.metadata.labels["nvidia.com/mig.config.state"]}' 2>/dev/null || echo "-")
    printf "%-45s %-25s %-12s\n" "${NODE}" "${profile}" "${state}"
  done
fi

echo ""
info "Run with --wide to include MIG config state"
info "Full label dump for a node:  oc describe node <node-name> | grep -A50 Labels"
