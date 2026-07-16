#!/usr/bin/env bash
# UC3: Multi-Tenant Quota Enforcement
# Charlie borrows idle quota from alice and bob's queues (cohort borrowing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login
header "UC3: Multi-Tenant Quota — applying 4 research jobs"
apply_template "${SCRIPT_DIR}/jobs.yaml"
echo ""
info "Watch admission:   oc get workloads -n research-team-project -w"
info "Check quotas:      oc get clusterqueues -o wide"
info "Cleanup:           bash ../../cleanup.sh uc3"
