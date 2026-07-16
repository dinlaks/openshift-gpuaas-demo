#!/usr/bin/env bash
# UC9: Time-Based GPU Policy
# CronJobs auto-switch between large-slice weekday and small-slice weekend mode.
# Run manually to demo the policy switch without waiting for the schedule.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login

MODE="${1:-weekday}"
case "$MODE" in
  weekday)
    header "UC9: Activate WEEKDAY policy (large GPU slice)"
    apply_template "${SCRIPT_DIR}/weekday-job.yaml"
    info "Show VRAM: oc logs -n inference-team-project -l demo/slot=weekday"
    ;;
  weekend)
    header "UC9: Activate WEEKEND policy (small economy slice)"
    oc delete job uc9-inference-weekday -n inference-team-project --ignore-not-found 2>/dev/null || true
    apply_template "${SCRIPT_DIR}/weekend-job.yaml"
    info "Show VRAM drop: oc logs -n inference-team-project -l demo/slot=weekend"
    ;;
  *) error "Usage: bash run-demo.sh [weekday|weekend]" ;;
esac
info "Cleanup: bash ../../cleanup.sh uc9"
