#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Deploy Kueue infrastructure: ResourceFlavors, ClusterQueues, LocalQueues,
# priority classes, and time-based policy.
#
# Usage:
#   bash deploy-kueue.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_env
resolve_gpu_config   # sets MIG_SMALL_RESOURCE, MIG_LARGE_RESOURCE, flavors from GPU_TYPE
require_oc_login

header "Kueue infrastructure (GPU_TYPE=${GPU_TYPE})"

# ResourceFlavors and ClusterQueues are templates — apply_template runs envsubst first
apply_template "${SCRIPT_DIR}/01-resource-flavors.yaml"

# Cohort must exist before ClusterQueues reference it (Kueue 1.3+)
apply_cr "${SCRIPT_DIR}/00-cohort.yaml"
apply_template "${SCRIPT_DIR}/02-cluster-queues.yaml"
apply_cr "${SCRIPT_DIR}/03-local-queues.yaml"
apply_cr "${SCRIPT_DIR}/04-workload-priority-classes.yaml"

# UC9 time-based policy — contains ${MIG_SMALL_RESOURCE} in ConfigMap template
apply_template "${SCRIPT_DIR}/09-time-based-policy.yaml"

# Label project namespaces for Kueue management.
# NOTE: Labels are added here (not at project creation) because RHOAI shows a
# "Kueue is disabled" banner when labels are present but Kueue is Unmanaged.
# Adding labels after RHOAI is ready avoids confusing the dashboard.
info "Labelling namespaces for Kueue management..."
for NS in inference-team-project ds-team-project research-team-project finetune-team-project analytics-project; do
  oc label namespace "${NS}" \
    kueue.openshift.io/managed=true \
    --overwrite 2>/dev/null && true
done
success "Namespaces labelled for Kueue"

# Remove default LocalQueues auto-created by RHOAI (point to default ClusterQueue
# which has no GPU resources — jobs sent there would pend indefinitely).
info "Removing auto-created default LocalQueues..."
for NS in inference-team-project ds-team-project research-team-project finetune-team-project analytics-project; do
  oc delete localqueue default -n "${NS}" --ignore-not-found 2>/dev/null || true
done
success "Default LocalQueues removed"

success "Kueue deployed"
info "Verify queues:  oc get clusterqueues,localqueues -A"
