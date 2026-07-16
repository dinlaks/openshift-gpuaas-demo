#!/usr/bin/env bash
# UC6: Hardware-Profile-Driven GPU Placement
# Two jobs — full GPU for large model inference, small MIG for dev workload.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login
header "UC6: Model Placement — full GPU + small MIG slice"
apply_template "${SCRIPT_DIR}/placement-jobs.yaml"
echo ""
info "Watch:   oc get pods -n inference-team-project -n research-team-project -w"
info "Show VRAM difference in logs:"
info "  oc logs -n inference-team-project -l demo/uc=uc6-placement"
info "  oc logs -n research-team-project  -l demo/uc=uc6-placement"
info "Cleanup: bash ../../cleanup.sh uc6"
