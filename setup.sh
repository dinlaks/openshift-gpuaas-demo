#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# GPU-as-a-Service on OpenShift — Single-cluster setup orchestrator
#
# Runs all setup steps in order on the cluster specified in env.sh.
# For multi-cluster (MultiKueue + ACM) see multi-cluster/README.md
#
# Usage:
#   bash setup.sh                  # full setup on Cluster A (OCP_API_URL in env.sh)
#   bash setup.sh --cluster <name> # target a named cluster (uses CLUSTER_<NAME>_* vars — e.g. --cluster <name>)
#   bash setup.sh --dry-run        # print changes, no apply
#   bash setup.sh --skip-operators # skip operator install (already installed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
SKIP_OPERATORS=false
TARGET_CLUSTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true ;;
    --skip-operators) SKIP_OPERATORS=true ;;
    --cluster)        shift; TARGET_CLUSTER="${1:-}" ;;
    *) error "Unknown argument: $1. Usage: bash setup.sh [--cluster <name>] [--dry-run] [--skip-operators]"; exit 1 ;;
  esac
  shift
done
export DRY_RUN

load_env

# ── Cluster targeting: --cluster <name> looks up CLUSTER_<NAME>_* vars in env.sh ──
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

# ── Pre-flight validation ─────────────────────────────────────────────────────
header "Pre-flight checks"
bash "${SCRIPT_DIR}/preflight-check.sh" || {
  error "Fix the issues above before running setup."
  exit 1
}

require_oc_login

# ── Step 1: Operators ─────────────────────────────────────────────────────────
if [[ "${SKIP_OPERATORS}" == "false" ]]; then
  header "Step 1: Deploy operators (NFD, GPU Operator, Kueue, RHOAI)"
  bash "${SCRIPT_DIR}/01-operators/deploy-operators.sh"
else
  info "Step 1: Skipping operator install (--skip-operators)"
fi

# ── Step 2: GPU node setup ────────────────────────────────────────────────────
header "Step 2: Label GPU nodes and configure MIG"
bash "${SCRIPT_DIR}/02-gpu-setup/01-node-labels.sh"

if [[ "${MIG_STRATEGY:-small}" == "dedicated" ]]; then
  info "MIG_STRATEGY=dedicated — skipping MIG partitioning (full GPU mode)"
  info "For timeslicing on dedicated nodes, see: 02-gpu-setup/03-timeslicing/"
else
  bash "${SCRIPT_DIR}/02-gpu-setup/02-mig/configure-mig.sh"
fi

# ── Step 3: RBAC ─────────────────────────────────────────────────────────────
header "Step 3: Configure RBAC (users, groups, projects)"
bash "${SCRIPT_DIR}/03-rbac/deploy-rbac.sh"

# ── Step 4: Hardware profiles ─────────────────────────────────────────────────
header "Step 4: Deploy RHOAI hardware profiles"
bash "${SCRIPT_DIR}/04-hardware-profiles/deploy-hardware-profiles.sh"

# ── Step 5: Kueue ─────────────────────────────────────────────────────────────
header "Step 5: Deploy Kueue queues and policies"
bash "${SCRIPT_DIR}/05-kueue/deploy-kueue.sh"

# ── Done ──────────────────────────────────────────────────────────────────────
success "Single-cluster setup complete!"
echo ""
info "Next steps:"
echo "  • Validate GPU resources:  bash 02-gpu-setup/05-validation/validate-nodes.sh"
echo "  • Run a use case:          cd use-cases/uc3-multi-tenant && bash run-demo.sh"
echo "  • Clean up between UCs:    bash cleanup.sh uc3"
echo "  • Multi-cluster add-on:    bash setup.sh --cluster <name>  (then see multi-cluster/README.md)"
