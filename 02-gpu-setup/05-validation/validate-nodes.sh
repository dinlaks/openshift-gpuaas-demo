#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Inspect GPU node labels — shows both our demo/gpu-* labels and the
# nvidia.com/gpu.* labels set automatically by NFD + GPU Operator.
#
# Usage:
#   bash validate-nodes.sh                    # validate Cluster A (OCP_API_URL)
#   bash validate-nodes.sh --cluster <name>        # validate named cluster
#   bash validate-nodes.sh --wide             # include MIG config state
#   bash validate-nodes.sh --cluster <name> --wide # both
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

WIDE=false
TARGET_CLUSTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wide)    WIDE=true ;;
    --cluster) shift; TARGET_CLUSTER="${1:-}" ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

load_env

if [[ -n "${TARGET_CLUSTER}" ]]; then
  _N=$(echo "${TARGET_CLUSTER}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  [[ -z "$(get_cluster_var "${TARGET_CLUSTER}" API_URL)" ]] && \
    error "CLUSTER_${_N}_API_URL not set in env.sh for --cluster ${TARGET_CLUSTER}" && exit 1
  export OCP_CLUSTER_TARGET="${TARGET_CLUSTER}"
  OCP_API_URL=$(get_cluster_var "${TARGET_CLUSTER}" API_URL)
  OCP_USERNAME=$(get_cluster_var "${TARGET_CLUSTER}" USERNAME)
  OCP_PASSWORD=$(get_cluster_var "${TARGET_CLUSTER}" PASSWORD)
  OCP_KUBECONFIG=$(get_cluster_var "${TARGET_CLUSTER}" KUBECONFIG)
  info "Targeting cluster: ${TARGET_CLUSTER} (CLUSTER_${_N}_*)"
fi

require_oc_login

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
  # go-template required for labels containing '/' — JSONPath bracket notation not supported
  gpu_type=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "demo/gpu-type"}}' 2>/dev/null); [[ -z "${gpu_type}" ]] && gpu_type="-"
  gpu_mem=$(oc get node "${NODE}"  -o go-template='{{index .metadata.labels "demo/gpu-memory"}}' 2>/dev/null); [[ -z "${gpu_mem}" ]] && gpu_mem="-"
  gpu_arch=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "demo/gpu-arch"}}' 2>/dev/null); [[ -z "${gpu_arch}" ]] && gpu_arch="-"
  has_small=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "demo/gpu-has-small-mig"}}' 2>/dev/null); [[ -z "${has_small}" ]] && has_small="-"
  has_large=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "demo/gpu-has-large-mig"}}' 2>/dev/null); [[ -z "${has_large}" ]] && has_large="-"
  has_full=$(oc get node "${NODE}"  -o go-template='{{index .metadata.labels "demo/gpu-has-full"}}' 2>/dev/null); [[ -z "${has_full}" ]] && has_full="-"

  [[ "${has_small}" == "true" ]] && has_small="yes" || has_small="-"
  [[ "${has_large}" == "true" ]] && has_large="yes" || has_large="-"
  [[ "${has_full}"  == "true" ]] && has_full="yes"  || has_full="-"

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
  product=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "nvidia.com/gpu.product"}}' 2>/dev/null); [[ -z "${product}" ]] && product="-"
  mem=$(oc get node "${NODE}"     -o go-template='{{index .metadata.labels "nvidia.com/gpu.memory"}}' 2>/dev/null); [[ -z "${mem}" ]] && mem="-"
  count=$(oc get node "${NODE}"   -o go-template='{{index .metadata.labels "nvidia.com/gpu.count"}}' 2>/dev/null); [[ -z "${count}" ]] && count="-"
  printf "%-45s %-40s %-8s %-6s\n" "${NODE}" "${product}" "${mem}" "${count}"
done

# ── MIG config state (--wide only) ───────────────────────────────────────────
if [[ "${WIDE}" == "true" ]]; then
  echo ""
  header "MIG config state (nvidia-mig-manager)"

  printf "%-45s %-25s %-12s\n" "NODE" "MIG-PROFILE" "STATE"
  printf "%-45s %-25s %-12s\n" "----" "-----------" "-----"

  for NODE in "${GPU_NODES[@]}"; do
    profile=$(oc get node "${NODE}" -o go-template='{{index .metadata.labels "nvidia.com/mig.config"}}' 2>/dev/null); [[ -z "${profile}" ]] && profile="-"
    state=$(oc get node "${NODE}"   -o go-template='{{index .metadata.labels "nvidia.com/mig.config.state"}}' 2>/dev/null); [[ -z "${state}" ]] && state="-"
    printf "%-45s %-25s %-12s\n" "${NODE}" "${profile}" "${state}"
  done
fi

echo ""
info "Run with --wide to include MIG config state"
info "Full label dump for a node:  oc describe node <node-name> | grep -A50 Labels"
