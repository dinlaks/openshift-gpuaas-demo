#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# UC2: Restore device plugin after DRA demo — run after UC2 is complete.
#
# What this script does:
#   1. Deletes UC2 demo pods (cleanup)
#   2. Uninstalls the nvidia-dra-driver-gpu Helm chart
#   3. Removes the DRA kubelet plugin node label
#   4. Re-enables the NVIDIA device plugin via ClusterPolicy patch
#   5. Waits for device plugin to recover (MIG slices advertised again)
#
# After this completes, UC3/UC4/UC5/UC7/UC8 are fully restored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
require_oc_login

header "DRA Teardown — restoring device plugin (post-UC2)"

# ── 1. Clean up UC2 demo pods ─────────────────────────────────────────────────
# Jobs own the ResourceClaims — deleting jobs cascades to ResourceClaim deletion automatically.
info "Cleaning up UC2 demo jobs ..."
oc delete job -l demo/uc=uc2-dra -n research-team-project --ignore-not-found
success "Demo pods cleaned up"

# ── 2. Uninstall DRA driver Helm chart ────────────────────────────────────────
info "Uninstalling dra-driver-nvidia-gpu Helm chart ..."
if helm status dra-driver-nvidia-gpu -n dra-driver-nvidia-gpu &>/dev/null; then
  helm uninstall dra-driver-nvidia-gpu -n dra-driver-nvidia-gpu
  success "Helm chart uninstalled"
else
  info "Helm chart not installed — skipping"
fi

# ── 3. Remove DRA node label ──────────────────────────────────────────────────
info "Removing DRA kubelet plugin node label ..."
GPU_NODE=$(oc get nodes -l nvidia.com/gpu.present=true -o name | head -1 | sed 's|node/||')
oc label node "${GPU_NODE}" nvidia.com/dra-kubelet-plugin- --overwrite 2>/dev/null || true
success "Node label removed"

# ── 4. Re-enable device plugin, restore ClusterPolicy ────────────────────────
# Keep cdi.enabled: true (needed for nvidia-cdi runtimeClass in other UCs).
# Keep cdi.default: false (DRA doc recommendation; default-kind fallback not needed).
info "Re-enabling NVIDIA device plugin, restoring ClusterPolicy ..."
oc patch clusterpolicy gpu-cluster-policy --type=merge \
  -p '{"spec":{"cdi":{"enabled":true,"default":false},"devicePlugin":{"enabled":true}}}'

wait_for "device plugin DaemonSet running" \
  "oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q Running" \
  180 10
success "Device plugin re-enabled"

# ── 5. Verify MIG slices restored (check count > 0, not just key presence) ───
wait_for "MIG slices advertised again" \
  "oc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/mig-1g\.6gb}' 2>/dev/null | grep -qv '^0$'" \
  120 10

echo ""
success "Device plugin restored — all use cases operational"
info "MIG resources on node:"
oc get node -o jsonpath='{.items[0].status.allocatable}' 2>/dev/null \
  | python3 -c "import sys,json; r={k:v for k,v in json.load(sys.stdin).items() if 'nvidia' in k or 'mig' in k}; [print(f'  {k}: {v}') for k,v in sorted(r.items())]"
