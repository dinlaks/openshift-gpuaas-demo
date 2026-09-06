#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Teardown time-slicing — restores GPU 1 to single nvidia.com/gpu (non-sliced).
# Usage: bash 02-gpu-setup/03-timeslicing/teardown-timeslicing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
resolve_gpu_config
require_oc_login

header "Tearing down GPU Time-Slicing"

# Early exit if time-slicing is not active (device-plugin-config doesn't exist)
if ! oc get configmap device-plugin-config -n nvidia-gpu-operator &>/dev/null; then
  info "Time-slicing not active (device-plugin-config absent) — nothing to tear down"
  exit 0
fi

info "Cleaning up demo jobs and pods (GPU must be free before MIG reset) ..."
oc delete job -l demo/uc=uc-timeslice -n ds-team-project --ignore-not-found
# Force-delete any lingering GPU pods so the mig-manager can reclaim the device
oc delete pods -n ds-team-project -l demo/scenario=timeslicing \
  --force --grace-period=0 --ignore-not-found 2>/dev/null || true
sleep 5

info "Removing time-slicing ClusterPolicy config ..."
oc patch clusterpolicy gpu-cluster-policy --type=json \
  -p='[{"op":"remove","path":"/spec/devicePlugin/config"}]' 2>/dev/null || \
oc patch clusterpolicy gpu-cluster-policy --type=merge \
  -p='{"spec":{"devicePlugin":{"config":null}}}'

info "Removing device-plugin ConfigMap ..."
oc delete configmap device-plugin-config -n nvidia-gpu-operator --ignore-not-found

info "Waiting for device plugin to restore single GPU ..."
wait_for "nvidia.com/gpu back to 1" \
  "[ \"\$(oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)\" = '1' ]" \
  120 10

info "Removing demo/gpu-has-full label ..."
oc label node -l nvidia.com/gpu.present=true demo/gpu-has-full- --overwrite 2>/dev/null || true

if [[ -n "${MIG_LARGE_RESOURCE:-}" ]]; then
  info "Restoring MIG on GPU 1 (switching back to ${MIG_PROFILE_MIXED}) ..."
  oc label node -l nvidia.com/gpu.present=true nvidia.com/mig.config="${MIG_PROFILE_MIXED}" --overwrite
  # Dots in resource names must be backslash-escaped for kubectl jsonpath field selectors.
  MIG_LARGE_JP="${MIG_LARGE_RESOURCE//./\\.}"
  wait_for "GPU 1 MIG restored (${MIG_LARGE_RESOURCE} = 1)" \
    "[ \"\$(oc get node -o jsonpath='{.items[0].status.allocatable.${MIG_LARGE_JP}}' 2>/dev/null)\" = '1' ]" \
    180 10
  echo ""
  success "Time-slicing removed — MIG restored to ${MIG_PROFILE_MIXED}"
else
  echo ""
  success "Time-slicing removed — non-MIG GPU, no MIG restore needed"
fi
