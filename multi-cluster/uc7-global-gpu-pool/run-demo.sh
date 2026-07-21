#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# UC7: Global GPU Pool — submit one job, MultiKueue dispatches to the cluster with capacity.
#
# Prerequisites: multi-cluster/ setup complete (01-acm-setup + 02-multikueue)
# Step 1 (optional): fill Cluster A's slots to force dispatch to Cluster B
# Step 2: submit the global job — watch it land on whichever cluster has capacity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
resolve_gpu_config

OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

STEP="${1:-2}"

case "$STEP" in
  1)
    header "UC7 Step 1: Fill Cluster A's GPU slots (forces dispatch to Cluster B)"
    apply_template "${SCRIPT_DIR}/07-uc7-cluster-a-fillers.yaml"
    info "Watch Cluster A queues fill up:"
    echo "  oc get clusterqueues -o wide"
    info "Next: bash run-demo.sh 2"
    ;;
  2)
    header "UC7 Step 2: Submit job to global queue — MultiKueue selects the cluster"
    apply_template "${SCRIPT_DIR}/../02-multikueue/07-uc7-demo-job.yaml"
    echo ""
    info "Watch dispatch on Cluster A (hub):"
    echo "  oc get workloads -n inference-team-project -w"
    echo "  oc get jobs -n inference-team-project"
    echo ""
    info "Check which cluster received the job:"
    echo "  oc get workload -n inference-team-project -o jsonpath='{.items[].status.admissionChecks}'"
    ;;
  *)
    error "Usage: bash run-demo.sh [1|2]"
    echo "  1 — fill Cluster A slots (optional, forces dispatch to Cluster B)"
    echo "  2 — submit global job (default)"
    exit 1
    ;;
esac

info "Cleanup: bash ../../cleanup.sh uc7"
