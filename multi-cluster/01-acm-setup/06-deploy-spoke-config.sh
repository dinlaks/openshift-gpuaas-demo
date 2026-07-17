#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Orchestrate full GPUaaS config deploy to Cluster B (Cluster B).
# Each step delegates to the owning folder's script with --cluster b.
# Run AFTER: 00-prereqs/deploy-prereqs.sh --cluster b
#        AND: 00-prereqs/acm/03-import-cluster-b.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/../.."
source "${ROOT}/lib/common.sh"
load_env

header "Deploying GPUaaS config to Cluster B (Cluster B)"

bash "${ROOT}/03-gpu-management/01-node-setup/node-labels-multinode.sh" cluster-b
bash "${ROOT}/02-gpu-setup/02-mig/configure-mig.sh"
bash "${ROOT}/02-rbac/deploy-rbac.sh" --cluster b
bash "${ROOT}/04-hardware-profiles/deploy-hardware-profiles.sh" --cluster b
bash "${ROOT}/06-kueue/deploy-kueue.sh" --cluster b

success "Cluster B fully configured — GPU resources available via ACM"
echo ""
info "Next: Configure MultiKueue for UC7 cross-cluster dispatch"
echo "  bash 07-acm/01-multikueue-setup.sh"
