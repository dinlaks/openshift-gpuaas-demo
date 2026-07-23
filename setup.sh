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
#   bash setup.sh --cluster b      # setup on Cluster B (uses CLUSTER_B_* vars — UC7 only)
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
    *) error "Unknown argument: $1. Usage: bash setup.sh [--cluster b] [--dry-run] [--skip-operators]"; exit 1 ;;
  esac
  shift
done
export DRY_RUN

load_env

# ── Multi-cluster: override OCP_* with CLUSTER_B_* when --cluster b is given ──
if [[ "${TARGET_CLUSTER}" == "b" ]]; then
  [[ -z "${CLUSTER_B_API_URL:-}"  ]] && error "CLUSTER_B_API_URL not set in env.sh" && exit 1
  [[ -z "${SPOKE_CLUSTER_USERNAME:-}" ]] && error "SPOKE_CLUSTER_USERNAME not set in env.sh" && exit 1
  [[ -z "${SPOKE_CLUSTER_PASSWORD:-}" ]] && error "SPOKE_CLUSTER_PASSWORD not set in env.sh" && exit 1
  export SPOKE_CLUSTER_OCP_API_URL="${CLUSTER_B_API_URL}"
  export SPOKE_CLUSTER_OCP_USERNAME="${SPOKE_CLUSTER_USERNAME:-}"
  export SPOKE_CLUSTER_OCP_PASSWORD="${SPOKE_CLUSTER_PASSWORD:-}"
  export SPOKE_CLUSTER_OCP_KUBECONFIG="${CLUSTER_B_KUBECONFIG:-}"
  OCP_API_URL="${CLUSTER_B_API_URL}"
  OCP_USERNAME="${SPOKE_CLUSTER_USERNAME:-}"
  OCP_PASSWORD="${SPOKE_CLUSTER_PASSWORD:-}"
  OCP_KUBECONFIG="${CLUSTER_B_KUBECONFIG:-}"
  info "Targeting Cluster B: ${OCP_API_URL}"
elif [[ -n "${TARGET_CLUSTER}" ]]; then
  error "Unknown cluster '${TARGET_CLUSTER}'. Only --cluster b is supported."
  exit 1
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
echo "  • Multi-cluster add-on:    bash setup.sh --cluster b  (then see multi-cluster/README.md)"
