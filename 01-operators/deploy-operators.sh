#!/usr/bin/env bash
# Deploy all required operators for the GPUaaS demo.
# Run this once per cluster before any other setup steps.
#
# Installs: cert-manager, NFD, GPU Operator, Kueue, RHOAI, Service Mesh, Serverless
#
# Usage:
#   bash deploy-operators.sh             # full deploy
#   bash deploy-operators.sh --dry-run   # print changes, no apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done
export DRY_RUN

load_env
require_oc_login

MANIFESTS="${SCRIPT_DIR}/manifests"

# ── cert-manager ──────────────────────────────────────────────────────────────
header "cert-manager (required by RHOAI 3.x)"
ensure_operator openshift-cert-manager-operator cert-manager-operator \
  "${MANIFESTS}/wave-1-cert-manager.yaml"
wait_operator openshift-cert-manager-operator cert-manager-operator 300
wait_for "cert-manager pods running" \
  "oc get pods -n cert-manager --no-headers 2>/dev/null | grep -q Running" 180

# ── Node Feature Discovery ────────────────────────────────────────────────────
header "Node Feature Discovery"
ensure_operator nfd openshift-nfd "${MANIFESTS}/wave-0-nfd-subscription.yaml"
wait_operator nfd openshift-nfd 300
wait_for "NodeFeatureDiscovery CRD registered" \
  "oc get crd nodefeaturediscoveries.nfd.openshift.io &>/dev/null" 60 5
if oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null; then
  info "NodeFeatureDiscovery nfd-instance already exists — skipping"
else
  apply_cr "${MANIFESTS}/wave-0-nfd-instance.yaml"
fi
wait_for "NFD pods running" \
  "oc get pods -n openshift-nfd --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q nfd" 300

# ── NVIDIA GPU Operator ────────────────────────────────────────────────────────
header "NVIDIA GPU Operator"
ensure_operator gpu-operator-certified nvidia-gpu-operator \
  "${MANIFESTS}/wave-0-gpu-operator-subscription.yaml"
wait_operator gpu-operator-certified nvidia-gpu-operator 300
wait_for "ClusterPolicy CRD registered" \
  "oc get crd clusterpolicies.nvidia.com &>/dev/null" 60 5
if oc get configmap device-plugin-config -n nvidia-gpu-operator &>/dev/null; then
  info "ConfigMap device-plugin-config already exists — skipping"
else
  apply_cr "${MANIFESTS}/wave-0-gpu-device-plugin-config.yaml"
fi
apply_cr "${MANIFESTS}/wave-0-gpu-cluster-policy.yaml"
if oc get podmonitor nvidia-dcgm-exporter -n gpu-monitoring &>/dev/null 2>&1; then
  info "PodMonitor nvidia-dcgm-exporter already exists — skipping"
else
  apply_cr "${MANIFESTS}/wave-0-dcgm-servicemonitor.yaml" || warn "DCGM ServiceMonitor skipped (monitoring may not be configured)"
fi
info "Waiting for NVIDIA driver DaemonSet (kernel compile — up to 10 min on bare metal)..."
wait_for "NVIDIA driver DaemonSet ready" \
  "oc get ds -n nvidia-gpu-operator --no-headers 2>/dev/null \
    | grep '^nvidia-driver-daemonset' | awk '{print \$4}' | grep -v '^0\$'" 600 20
wait_for "NVIDIA device plugin ready" \
  "oc get ds nvidia-device-plugin-daemonset -n nvidia-gpu-operator --no-headers 2>/dev/null \
    | awk '{print \$4}' | grep -v '^0\$'" 300 10

# ── Service Mesh + Serverless (required by RHOAI KServe) ─────────────────────
header "Service Mesh 3 + Serverless"
ensure_operator servicemeshoperator3 openshift-operators \
  "${MANIFESTS}/wave-1-servicemesh3-subscription.yaml"
ensure_operator serverless-operator openshift-serverless \
  "${MANIFESTS}/wave-1-serverless-subscription.yaml"
wait_operator servicemeshoperator3 openshift-operators 300
wait_operator serverless-operator openshift-serverless 300

# ── Red Hat build of Kueue ────────────────────────────────────────────────────
header "Red Hat build of Kueue"
ensure_operator openshift-kueue-operator openshift-kueue-operator \
  "${MANIFESTS}/wave-1-kueue-subscription.yaml"
wait_operator openshift-kueue-operator openshift-kueue-operator 300

# ── Red Hat OpenShift AI ──────────────────────────────────────────────────────
header "Red Hat OpenShift AI (RHOAI)"
ensure_operator rhods-operator redhat-ods-operator \
  "${MANIFESTS}/wave-1-rhoai-subscription.yaml"
wait_operator rhods-operator redhat-ods-operator 300
wait_for "DSCInitialization CRD registered" \
  "oc get crd dscinitializations.dscinitialization.opendatahub.io &>/dev/null" 60 5
wait_for "RHOAI operator pod ready" \
  "oc get pods -n redhat-ods-operator -l name=rhods-operator \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q ." 120 5
if oc get dscinitializations default-dsci &>/dev/null; then
  info "DSCInitialization default-dsci already exists — skipping"
else
  apply_cr "${MANIFESTS}/wave-1-rhoai-dsci.yaml"
fi
wait_for "DSCInitialization ready" \
  "oc get dscinitializations default-dsci \
    -o jsonpath='{.status.phase}' 2>/dev/null | grep -qi ready" 180
if oc get datasciencecluster default-dsc &>/dev/null; then
  info "DataScienceCluster default-dsc already exists — skipping"
else
  apply_cr "${MANIFESTS}/wave-1-rhoai-datasciencecluster.yaml"
fi
wait_for "DataScienceCluster ready" \
  "oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.phase}' 2>/dev/null | grep -qi ready" 600
wait_for "RHOAI dashboard pod running" \
  "oc get pod -n redhat-ods-applications -l app=rhods-dashboard --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q ." 300

success "All operators deployed on $(oc whoami --show-server)"
