#!/usr/bin/env bash
# UC4: Queue-Based Scheduling
# Step 1: fill all GPU slots. Step 2: submit overflow job → goes Inadmissible.
# Step 3: delete one running job → Kueue auto-admits the queued job.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login

STEP="${1:-1}"
case "$STEP" in
  1)
    header "UC4 Step 1: Fill all GPU slots (4 jobs)"
    apply_template "${SCRIPT_DIR}/fill-jobs.yaml"
    info "Watch: oc get workloads -n research-team-project -w"
    info "Next:  bash run-demo.sh 2"
    ;;
  2)
    header "UC4 Step 2: Submit overflow job (goes Inadmissible)"
    apply_template "${SCRIPT_DIR}/overflow-job.yaml"
    info "Show:  oc get workloads -n research-team-project"
    info "Next:  oc delete job charlie-research-queue-1 -n research-team-project"
    info "Then:  watch the overflow job auto-admit"
    ;;
  *) error "Usage: bash run-demo.sh [1|2]" ;;
esac
info "Cleanup: bash ../../cleanup.sh uc4"
