#!/usr/bin/env bash
# Teardown time-slicing — restores GPU 1 to single nvidia.com/gpu (non-sliced).
# Usage: bash 03-gpu-management/05-timeslicing/teardown-timeslicing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
require_oc_login

header "Tearing down GPU Time-Slicing"

info "Cleaning up demo jobs ..."
oc delete job -l demo/uc=uc-timeslice -n gpu-premium-project --ignore-not-found

info "Removing time-slicing ClusterPolicy config ..."
oc patch clusterpolicy gpu-cluster-policy --type=json \
  -p='[{"op":"remove","path":"/spec/devicePlugin/config"}]' 2>/dev/null || \
oc patch clusterpolicy gpu-cluster-policy --type=merge \
  -p='{"spec":{"devicePlugin":{"config":null}}}'

info "Removing device-plugin ConfigMap ..."
oc delete configmap device-plugin-config -n nvidia-gpu-operator --ignore-not-found

info "Waiting for device plugin to restore single GPU ..."
wait_for "nvidia.com/gpu back to 1" \
  "[ \$(oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null) -eq 1 ]" \
  120 10

echo ""
success "Time-slicing removed — GPU 1 back to 1x nvidia.com/gpu"
