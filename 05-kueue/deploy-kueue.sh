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

# Detect GPU product label from the node's actual nvidia.com/gpu.product label.
# GPU Operator (GFD) sets this — e.g. NVIDIA-A30 (no timeslicing) or NVIDIA-A30-SHARED (timeslicing).
# We use it as-is in ResourceFlavor nodeLabels (scheduling always matches node) AND
# patch the DCGM ServiceMonitor metricRelabeling so DCGM's modelName matches for the dashboard.
resolve_gpu_product_label() {
  GPU_PRODUCT_LABEL=$(oc get nodes -l nvidia.com/gpu.present=true \
    -o jsonpath='{.items[0].metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || echo "")
  if [[ -z "${GPU_PRODUCT_LABEL}" ]]; then
    warn "Could not detect nvidia.com/gpu.product from node — RHOAI Infrastructure dashboard may not show GPU model tags"
    return 0
  fi
  info "GPU product label (from node): ${GPU_PRODUCT_LABEL}"
  export GPU_PRODUCT_LABEL

  # Patch DCGM ServiceMonitor to rename modelName to match the node label.
  # DCGM reports hardware model name (e.g. "NVIDIA A30") while GPU Operator labels nodes
  # with a sanitized form (e.g. "NVIDIA-A30-SHARED"). The relabeling bridges the gap so
  # the RHOAI 3.5 Infrastructure dashboard per-queue gauges show real utilization.
  info "Patching DCGM ServiceMonitor metricRelabelings for dashboard compatibility..."
  oc patch servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "endpoints": [{
      "path": "/metrics",
      "port": "gpu-metrics",
      "metricRelabelings": [{
        "sourceLabels": ["modelName"],
        "regex": ".+",
        "targetLabel": "modelName",
        "replacement": "${GPU_PRODUCT_LABEL}",
        "action": "replace"
      }]
    }]
  }
}
PATCH
)" 2>/dev/null && success "DCGM ServiceMonitor patched: modelName → ${GPU_PRODUCT_LABEL}" || \
    warn "Could not patch DCGM ServiceMonitor — per-queue utilization may show 0%"
}
resolve_gpu_product_label

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

# PrometheusRule to aggregate MIG GPU metrics for RHOAI 3.5 Infrastructure dashboard
apply_cr "${SCRIPT_DIR}/10-mig-utilization-rule.yaml"

success "Kueue deployed"
info "Verify queues:  oc get clusterqueues,localqueues -A"
info "Run 02-gpu-setup/06-dcgm-pod-attribution.sh to enable per-queue utilization in RHOAI dashboard"
