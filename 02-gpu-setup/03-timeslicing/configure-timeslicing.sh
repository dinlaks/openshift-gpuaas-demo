#!/usr/bin/env bash
# Enable GPU time-slicing on Cluster A GPU 1 (full A30, non-MIG).
# Creates 4 virtual GPUs from 1 physical GPU.
#
# NOTE: GPU 0 stays in MIG mode — time-slicing applies to nvidia.com/gpu (GPU 1) only.
# NOTE: This conflicts with DRA (UC2) which also uses GPU 1.
#       Run teardown-dra.sh before this if DRA is active.
#
# Usage: bash 03-gpu-management/05-timeslicing/configure-timeslicing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
require_oc_login

header "Configuring GPU Time-Slicing on Cluster A GPU 1"

# Check DRA is not active
if helm status dra-driver-nvidia-gpu -n dra-driver-nvidia-gpu &>/dev/null 2>&1; then
  error "DRA driver is running — run teardown-dra.sh first (DRA and time-slicing both use GPU 1)"
  exit 1
fi

info "Applying device-plugin time-slicing ConfigMap ..."
apply_cr "${SCRIPT_DIR}/device-plugin-timeslice-config.yaml"

info "Patching ClusterPolicy to use time-slicing config ..."
oc patch clusterpolicy gpu-cluster-policy --type=merge -p '{
  "spec": {
    "devicePlugin": {
      "config": {
        "name": "device-plugin-config",
        "default": "a30-timeslice"
      }
    }
  }
}'

info "Waiting for device plugin to reload with time-slicing config ..."
wait_for "device plugin pods restarted" \
  "oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q Running" \
  120 10

sleep 15  # allow node capacity to update

wait_for "time-sliced GPUs advertised (nvidia.com/gpu >= 4)" \
  "[ \$(oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null) -ge 4 ]" \
  60 5

echo ""
success "Time-slicing active — GPU 1 advertising 4x nvidia.com/gpu"
info "Node GPU resources:"
oc get node -o jsonpath='{.items[0].status.allocatable}' 2>/dev/null \
  | python3 -c "import sys,json; r={k:v for k,v in json.load(sys.stdin).items() if 'nvidia' in k or 'mig' in k}; [print(f'  {k}: {v}') for k,v in sorted(r.items())]"
echo ""
info "Apply demo jobs:"
echo "  oc apply -f 03-gpu-management/05-timeslicing/inference-job-timesliced.yaml"
