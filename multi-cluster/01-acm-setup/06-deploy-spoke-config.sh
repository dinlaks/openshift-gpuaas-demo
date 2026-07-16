#!/usr/bin/env bash
# Orchestrate full GPUaaS config deploy to Cluster B (Dell 750 #2).
# Each step delegates to the owning folder's script with --cluster b.
# Run AFTER: 00-prereqs/deploy-prereqs.sh --cluster b
#        AND: 00-prereqs/acm/03-import-cluster-b.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/../.."
source "${ROOT}/lib/common.sh"
load_env

header "Deploying GPUaaS config to Cluster B (Dell 750 #2)"

bash "${ROOT}/03-gpu-management/01-node-setup/node-labels-multinode.sh" cluster-b
bash "${ROOT}/03-gpu-management/02-mig/configure-a30-mig.sh" cluster-b-profile
bash "${ROOT}/02-rbac/deploy-rbac.sh" --cluster b
bash "${ROOT}/04-hardware-profiles/deploy-hardware-profiles.sh" --cluster b
bash "${ROOT}/06-kueue/deploy-kueue.sh" --cluster b

success "Cluster B fully configured — both A30 GPUs available via ACM"
echo ""
info "Next: Configure MultiKueue for UC7 cross-cluster dispatch"
echo "  bash 07-acm/01-multikueue-setup.sh"
