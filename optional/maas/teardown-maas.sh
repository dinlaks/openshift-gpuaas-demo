#!/usr/bin/env bash
# Teardown MaaS — removes InferenceService, ServingRuntime, and maas-project.
# GPU 1 returns to pool after InferenceService pod is deleted.
# Usage: bash 08-maas/teardown-maas.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_env
OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

header "MaaS Teardown"

info "Deleting InferenceService ..."
oc delete inferenceservice granite-maas -n maas-project --ignore-not-found

info "Deleting ServingRuntime ..."
oc delete servingruntime vllm-maas-runtime -n maas-project --ignore-not-found

info "Deleting maas-project namespace ..."
oc delete namespace maas-project --ignore-not-found

info "Cleaning up token files ..."
rm -f /tmp/maas-token-{alice,bob,charlie}.txt 2>/dev/null || true

echo ""
success "MaaS teardown complete — GPU 1 returned to pool"
