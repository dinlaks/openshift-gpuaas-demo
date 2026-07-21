#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# GPU-as-a-Service on OpenShift — Single-cluster setup orchestrator
#
# Runs all setup steps in order on the cluster specified in env.sh.
# For multi-cluster (MultiKueue + ACM) see multi-cluster/README.md
#
# Usage:
#   bash setup.sh                  # full setup
#   bash setup.sh --dry-run        # print changes, no apply
#   bash setup.sh --skip-operators # skip operator install (already installed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
SKIP_OPERATORS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true ;;
    --skip-operators) SKIP_OPERATORS=true ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done
export DRY_RUN

load_env

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
echo "  • Multi-cluster add-on:    see multi-cluster/README.md"
