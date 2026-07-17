#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# UC8: Gang Scheduling — All GPUs Must Start Together
# Fillers occupy 3 of 4 MIG slots; gang job waits. Delete fillers → all 4 start at once.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login

STEP="${1:-1}"
case "$STEP" in
  1)
    header "UC8 Step 1: Fill 3 of 4 MIG slots + submit 4-pod gang job"
    apply_template "${SCRIPT_DIR}/gang-job.yaml"
    info "Show gang Inadmissible: oc get workloads -n research-team-project"
    info "Show zero gang pods:    oc get pods -n research-team-project -l demo/role=gang"
    info "Next: bash run-demo.sh 2"
    ;;
  2)
    header "UC8 Step 2: Delete fillers → all 4 gang pods start simultaneously"
    oc delete job filler-job-1 filler-job-2 filler-job-3 \
      -n research-team-project --ignore-not-found
    info "Watch: oc get pods -n research-team-project -l demo/role=gang -w"
    ;;
  *) error "Usage: bash run-demo.sh [1|2]" ;;
esac
info "Cleanup: bash ../../cleanup.sh uc8"
