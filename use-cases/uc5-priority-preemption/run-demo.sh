#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# UC5: Workload Priority & Preemption
# Medium-priority dev job fills alice's slot, then high-priority production job preempts it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login

STEP="${1:-1}"
case "$STEP" in
  1)
    header "UC5 Step 1: Submit medium-priority dev job (fills slot)"
    apply_template "${SCRIPT_DIR}/fill-jobs.yaml"
    info "Watch: oc get pods -n inference-team-project -w"
    info "Next:  bash run-demo.sh 2"
    ;;
  2)
    header "UC5 Step 2: Submit high-priority inference job (preempts medium)"
    apply_template "${SCRIPT_DIR}/preemptor-job.yaml"
    info "Watch preemption: oc get workloads -n inference-team-project -w"
    info "Show preempted:   oc get workload -n inference-team-project -o wide"
    ;;
  *) error "Usage: bash run-demo.sh [1|2]" ;;
esac
info "Cleanup: bash ../../cleanup.sh uc5"
