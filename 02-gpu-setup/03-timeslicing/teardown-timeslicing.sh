#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Teardown time-slicing — restores GPU 1 to single nvidia.com/gpu (non-sliced).
# Usage: bash 02-gpu-setup/03-timeslicing/teardown-timeslicing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
require_oc_login

header "Tearing down GPU Time-Slicing"

info "Cleaning up demo jobs ..."
oc delete job -l demo/uc=uc-timeslice -n inference-team-project --ignore-not-found

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

info "Restoring MIG on GPU 1 (switching back to mixed-a30) ..."
oc label node -l nvidia.com/gpu.present=true nvidia.com/mig.config=mixed-a30 --overwrite

wait_for "GPU 1 MIG restored (nvidia.com/mig-2g.12gb = 1)" \
  "[ \"\$(oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/mig-2g\.12gb}' 2>/dev/null)\" = '1' ]" \
  180 10

echo ""
success "Time-slicing removed — MIG restored to mixed-a30"
