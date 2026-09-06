#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Enable GPU time-slicing on Cluster A full GPU (non-MIG mode).
# Creates TIMESLICE_REPLICAS virtual GPUs from 1 physical GPU (resolved from GPU_TYPE).
#
# NOTE: GPU 0 stays in MIG mode — time-slicing applies to nvidia.com/gpu (GPU 1) only.
# NOTE: This conflicts with DRA (UC2) which also uses GPU 1.
#       Run teardown-dra.sh before this if DRA is active.
#
# Usage: bash 02-gpu-setup/03-timeslicing/configure-timeslicing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
resolve_gpu_config
require_oc_login

header "Configuring GPU Time-Slicing on Cluster A GPU 1"

# Check DRA is not active
if helm status dra-driver-nvidia-gpu -n dra-driver-nvidia-gpu &>/dev/null 2>&1; then
  error "DRA driver is running — run teardown-dra.sh first (DRA and time-slicing both use GPU 1)"
  exit 1
fi

if [[ -n "${MIG_LARGE_RESOURCE:-}" ]]; then
  info "Disabling MIG on GPU 1 (switching to ${MIG_PROFILE_FULL_COMBO}) ..."
  oc label node -l nvidia.com/gpu.present=true nvidia.com/mig.config="${MIG_PROFILE_FULL_COMBO}" --overwrite
  # Dots in resource names must be backslash-escaped for kubectl jsonpath field selectors.
  MIG_LARGE_JP="${MIG_LARGE_RESOURCE//./\\.}"
  wait_for "GPU 1 MIG disabled (${MIG_LARGE_RESOURCE} = 0)" \
    "val=\$(oc get node -o jsonpath='{.items[0].status.allocatable.${MIG_LARGE_JP}}' 2>/dev/null); [ \"\$val\" = '0' ] || [ \"\$val\" = '' ]" \
    180 10
else
  info "Non-MIG GPU — skipping MIG disable step (GPU is always in full mode)"
fi

info "Setting demo/gpu-has-full=true label (required by gpu-full hardware profile and timeslicing jobs) ..."
oc label node -l nvidia.com/gpu.present=true demo/gpu-has-full=true --overwrite

info "Applying device-plugin time-slicing ConfigMap (${TIMESLICE_REPLICAS} replicas) ..."
apply_template "${SCRIPT_DIR}/device-plugin-timeslice-config.yaml"

info "Patching ClusterPolicy to use time-slicing config ..."
oc patch clusterpolicy gpu-cluster-policy --type=merge -p '{
  "spec": {
    "devicePlugin": {
      "config": {
        "name": "device-plugin-config",
        "default": "gpu-timeslice"
      }
    }
  }
}'

info "Waiting for device plugin to reload with time-slicing config ..."
wait_for "device plugin pods restarted" \
  "oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q Running" \
  120 10

sleep 15  # allow node capacity to update

wait_for "time-sliced GPUs advertised (nvidia.com/gpu >= ${TIMESLICE_REPLICAS})" \
  "[ \$(oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null) -ge ${TIMESLICE_REPLICAS} ]" \
  60 5

echo ""
success "Time-slicing active — GPU 1 advertising ${TIMESLICE_REPLICAS}x nvidia.com/gpu"
info "Node GPU resources:"
oc get node -o jsonpath='{.items[0].status.allocatable}' 2>/dev/null \
  | python3 -c "import sys,json; r={k:v for k,v in json.load(sys.stdin).items() if 'nvidia' in k or 'mig' in k}; [print(f'  {k}: {v}') for k,v in sorted(r.items())]"
echo ""
info "Submitting demo inference jobs (${TIMESLICE_REPLICAS} concurrent pods) ..."
apply_template "${SCRIPT_DIR}/inference-job-timesliced.yaml"
echo ""
info "Watch pods:  oc get pods -n ds-team-project -l demo/scenario=timeslicing -w"
info "Watch logs:  oc logs -n ds-team-project -l demo/scenario=timeslicing --prefix --follow --tail=5"
