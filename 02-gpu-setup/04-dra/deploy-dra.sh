#!/usr/bin/env bash
# UC2: Enable DRA for demo — toggles device plugin off, installs DRA driver via Helm.
#
# Prerequisites (must be done before running):
#   1. GPU Operator v25.10.1 installed (wave-0-gpu-operator-subscription.yaml — channel v25.10)
#   2. node-labels-multinode.sh --cluster a  (sets demo/gpu-gpu1-mode=full)
#   3. helm available on PATH
#
# What this script does:
#   0. Ensures CRI-O CDI scanning is enabled (MachineConfig — one-time node reboot if not set)
#   1. Verifies prerequisites (node label, GPU Operator version, helm)
#   2. Patches ClusterPolicy: cdi.enabled=true, cdi.default=false, devicePlugin.enabled=false
#   3. Labels the node for the DRA kubelet plugin
#   4. Removes stale nvidia-dra-driver namespace (old chart name) if present
#   5. Installs dra-driver-nvidia-gpu v0.4.0 via Helm
#   6. Waits for ResourceSlices to appear
#   7. Applies DeviceClass + ResourceClaimTemplates
#
# Key findings from OCP 4.21 / K8s 1.34 validation (2026-05-28):
#   - DRA API is resource.k8s.io/v1 (not v1beta1 — promoted to GA in K8s 1.34)
#   - DeviceRequest uses `exactly:` wrapper (not allocationMode: ExactCount)
#   - MIG attribute is `profile` not `migProfile` in ResourceSlices
#   - Helm --set-string required for nodeSelector bool values (not --set)
#   - CRI-O cdi_spec_dirs must be enabled for DRA device injection to work
#   - Demo pods use runtimeClassName: nvidia-cdi for CDI-aware device injection
#
# After UC2 demo: run teardown-dra.sh to re-enable device plugin for other UCs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_env
require_oc_login

header "DRA Setup — Cluster A (UC2)"

# ── 0. Ensure CRI-O CDI scanning is enabled ───────────────────────────────────
# Without cdi_spec_dirs configured, CRI-O cannot inject the exact DRA-allocated
# device into the container. This MachineConfig adds 99-cdi.conf to CRI-O's
# drop-in directory. It is a one-time operation that reboots the node (~10-15 min).
CDI_ENABLED=$(oc get machineconfig 99-crio-enable-cdi --no-headers 2>/dev/null | grep -c '99-crio-enable-cdi' || true)
if [[ "${CDI_ENABLED}" -eq 0 ]]; then
  warn "CRI-O CDI scanning not enabled. Applying MachineConfig — node will reboot (~10-15 min)."
  apply_cr "${SCRIPT_DIR}/00-crio-cdi-machineconfig.yaml"

  info "Waiting for MachineConfigPool to start updating ..."
  sleep 30
  wait_for "MachineConfigPool master updated" \
    "oc get mcp master -o jsonpath='{.status.conditions[?(@.type==\"Updated\")].status}' 2>/dev/null | grep -q True" \
    900 20

  info "Waiting for node to be Ready after reboot ..."
  wait_for "Node Ready" \
    "oc get nodes --no-headers 2>/dev/null | grep -q ' Ready'" \
    300 15

  success "Node rebooted and Ready — CDI enabled in CRI-O"
  info "Re-authenticating after reboot ..."
  require_oc_login
else
  success "CRI-O CDI scanning already enabled (MachineConfig present)"
fi

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
info "Checking prerequisites ..."

if ! oc get nodes -l "demo/gpu-gpu1-mode=full" --no-headers | grep -q .; then
  error "Node label demo/gpu-gpu1-mode=full not found."
  error "Run first: bash 03-gpu-management/01-node-setup/node-labels-multinode.sh --cluster a"
  exit 1
fi

if ! command -v helm &>/dev/null; then
  error "helm not found on PATH. Install helm v3+ and retry."
  exit 1
fi

GPU_OP_VERSION=$(oc get csv -n nvidia-gpu-operator --no-headers 2>/dev/null \
  | grep gpu-operator-certified | grep -oE 'v[0-9]+\.[0-9]+' | head -1)
if [[ -n "${GPU_OP_VERSION}" && "${GPU_OP_VERSION}" < "v25" ]]; then
  error "GPU Operator ${GPU_OP_VERSION} detected. DRA requires v25.10+."
  error "Apply 00-prereqs/manifests/wave-0-gpu-operator-subscription.yaml and wait for upgrade."
  exit 1
fi

success "Prerequisites verified"

# ── 2. Configure ClusterPolicy for DRA ────────────────────────────────────────
# Per DRA documentation: enable CDI (required for device injection) and disable
# the device plugin (DRA and device plugin cannot run simultaneously on the same node).
# cdi.default: false — DRA driver writes per-claim CDI specs; default-kind fallback is not needed.
info "Configuring ClusterPolicy for DRA (CDI enabled, device plugin disabled) ..."
oc patch clusterpolicy gpu-cluster-policy --type=merge \
  -p '{"spec":{"cdi":{"enabled":true,"default":false},"devicePlugin":{"enabled":false}}}'
wait_for "device plugin pods gone" \
  "! oc get pods -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q Running" \
  120 10
success "ClusterPolicy updated: CDI enabled, device plugin disabled"

# ── 3. Label node for DRA kubelet plugin ───────────────────────────────────────
GPU_NODE=$(oc get nodes -l nvidia.com/gpu.present=true -o name | head -1 | sed 's|node/||')
info "Labeling ${GPU_NODE} for DRA kubelet plugin ..."
oc label node "${GPU_NODE}" nvidia.com/dra-kubelet-plugin=true --overwrite
success "Node labeled"

# ── 4. Clean up any stale DRA driver from previous installs ──────────────────
# Old chart name was nvidia-dra-driver-gpu (namespace: nvidia-dra-driver).
# New chart is dra-driver-nvidia-gpu (namespace: dra-driver-nvidia-gpu).
# Remove the old namespace so stale pods don't confuse kubectl/oc output.
if oc get namespace nvidia-dra-driver &>/dev/null; then
  warn "Removing stale nvidia-dra-driver namespace from previous install ..."
  oc delete namespace nvidia-dra-driver --ignore-not-found
  success "Stale namespace removed"
fi

# ── 5. Install DRA driver via Helm ─────────────────────────────────────────
# Chart: kubernetes-sigs/dra-driver-nvidia-gpu v0.4.0 (OCI registry — no repo add needed)
# Migrated from NVIDIA/k8s-dra-driver-gpu to kubernetes-sigs in May 2026.
# v0.4.0 fixes Ampere MIG CDI injection (A30 is Ampere — old v25.12.0 was broken).
# Release name changed: nvidia-dra-driver-gpu → dra-driver-nvidia-gpu
info "Installing dra-driver-nvidia-gpu v0.4.0 (kubernetes-sigs OCI chart) ..."
# resources.gpus.enabled=true     → enables GPU/static MIG allocation feature in the DRA driver
# gpuResourcesEnabledOverride=true → required safety acknowledgment that device plugin is disabled;
#                                    chart refuses to install without this when resources.gpus.enabled=true
helm upgrade --install dra-driver-nvidia-gpu \
  oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu \
  --version="0.4.0" \
  --create-namespace \
  --namespace dra-driver-nvidia-gpu \
  --set nvidiaDriverRoot=/run/nvidia/driver \
  --set resources.gpus.enabled=true \
  --set gpuResourcesEnabledOverride=true \
  --set-string "kubeletPlugin.nodeSelector.nvidia\\.com/dra-kubelet-plugin=true" \
  --wait --timeout=5m

success "DRA driver installed"

# ── 6. Wait for ResourceSlices ────────────────────────────────────────────────
info "Waiting for ResourceSlices (DRA driver publishing GPUs) ..."
wait_for "ResourceSlices published" \
  "oc get resourceslices --no-headers 2>/dev/null | grep -q 'gpu.nvidia.com'" \
  180 10

info "ResourceSlices:"
oc get resourceslices 2>/dev/null

# ── 7. Apply DeviceClass + ResourceClaimTemplates ─────────────────────────────
info "Applying DeviceClass ..."
apply_cr "${SCRIPT_DIR}/01-device-class.yaml"

info "Applying ResourceClaimTemplates ..."
apply_cr "${SCRIPT_DIR}/02-resource-claim-template.yaml"

echo ""
success "DRA ready for UC2 demo!"
echo ""
info "Run the demo:"
echo "  oc apply -f 03-gpu-management/03-dra/03-dra-demo-pod.yaml"
echo "  oc get resourceclaim -n research-team-project -w"
echo "  oc get pods -n research-team-project -l demo/uc=uc2-dra"
echo ""
warn "When UC2 is done, restore device plugin for other use cases:"
echo "  bash 03-gpu-management/03-dra/teardown-dra.sh"
