#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# UC3: Multi-Tenant Quota Enforcement
#
# Usage (from repo root):
#   bash use-cases/uc3-multi-tenant/run-demo.sh    # Step 1: 4 charlie jobs (cohort borrowing)
#   bash use-cases/uc3-multi-tenant/run-demo.sh 2  # Step 2: overflow job (Inadmissible)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env; resolve_gpu_config; require_oc_login

STEP="${1:-1}"

case "$STEP" in
  1)
    header "UC3 Step 1: Multi-Tenant Quota — applying 4 research jobs (cohort borrowing)"
    apply_template "${SCRIPT_DIR}/jobs.yaml"
    echo ""
    info "Watch admission:   oc get workloads -n research-team-project -w"
    info "Check quotas:      oc get clusterqueue research-cluster-queue -o wide"
    info "Next:              bash use-cases/uc3-multi-tenant/run-demo.sh 2  (overflow demo)"
    ;;
  2)
    header "UC3 Step 2: Quota Enforcement — 5th job goes Inadmissible (not failed)"
    apply_template "${SCRIPT_DIR}/overflow-job.yaml"
    echo ""
    info "Watch Inadmissible state: oc get workloads -n research-team-project"
    info "Delete a running job to watch auto-admission: oc delete job charlie-research-job-1 -n research-team-project"
    ;;
  *)
    error "Usage: bash run-demo.sh [1|2]"
    echo "  1 — 4 charlie jobs demonstrating cohort borrowing (default)"
    echo "  2 — overflow job showing Inadmissible quota enforcement"
    exit 1
    ;;
esac

info "Cleanup: bash cleanup.sh uc3"
