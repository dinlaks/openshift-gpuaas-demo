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

header "Deploying GPUaaS config to Cluster B"

bash "${ROOT}/02-gpu-setup/01-node-labels.sh"
bash "${ROOT}/02-gpu-setup/02-mig/configure-mig.sh"
bash "${ROOT}/03-rbac/deploy-rbac.sh"
bash "${ROOT}/04-hardware-profiles/deploy-hardware-profiles.sh"
bash "${ROOT}/05-kueue/deploy-kueue.sh"

success "Cluster B fully configured — GPU resources available via ACM"
echo ""
info "Next: Configure MultiKueue for UC7 cross-cluster dispatch"
echo "  bash multi-cluster/02-multikueue/01-multikueue-setup.sh"
