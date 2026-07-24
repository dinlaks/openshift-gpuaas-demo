#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Import the spoke cluster into ACM Hub using API token — entirely from Hub.
# No kubeconfig file, no context switching, no manual steps on the spoke.
#
# Reads SPOKE_CLUSTER_TARGET from env.sh to identify which CLUSTER_<NAME>_* vars to use.
# ACM auto-import-secret accepts: server URL + bearer token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env

[[ -z "${SPOKE_CLUSTER_TARGET:-}" ]] && error "SPOKE_CLUSTER_TARGET not set in env.sh (e.g. SPOKE_CLUSTER_TARGET=ai160)" && exit 1
[[ -z "$(get_cluster_var "${SPOKE_CLUSTER_TARGET}" API_URL)" ]] && \
  error "CLUSTER_$(echo "${SPOKE_CLUSTER_TARGET}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_API_URL not set in env.sh" && exit 1
[[ -n "${CLUSTER_A_KUBECONFIG:-}" ]] && export KUBECONFIG="${CLUSTER_A_KUBECONFIG}"

# ── Step 1: Stay on Hub throughout ────────────────────────────────────────────
OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

SPOKE_API_URL=$(get_cluster_var "${SPOKE_CLUSTER_TARGET}" API_URL)
SPOKE_USERNAME=$(get_cluster_var "${SPOKE_CLUSTER_TARGET}" USERNAME)
SPOKE_PASSWORD=$(get_cluster_var "${SPOKE_CLUSTER_TARGET}" PASSWORD)

header "Importing spoke cluster (${SPOKE_CLUSTER_TARGET}) into ACM Hub via API token"

# ── Step 2: Obtain a token from spoke cluster using a temp kubeconfig ─────────
# Uses a throwaway KUBECONFIG so the main oc session (Hub) is never touched.
info "Logging into spoke cluster to get an API token (temp kubeconfig)..."
TMPKUBE=$(mktemp)
trap "rm -f ${TMPKUBE}" EXIT

KUBECONFIG="${TMPKUBE}" oc login "${SPOKE_API_URL}" \
  -u "${SPOKE_USERNAME}" \
  -p "${SPOKE_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null

SPOKE_TOKEN=$(KUBECONFIG="${TMPKUBE}" oc whoami -t)

if [[ -z "${SPOKE_TOKEN}" ]]; then
  error "Could not obtain token for spoke cluster. Check CLUSTER_$(echo "${SPOKE_CLUSTER_TARGET}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_* credentials in env.sh"
  exit 1
fi

# Use SPOKE_CLUSTER_TARGET as the ACM ManagedCluster name — clear and user-controlled
SPOKE_CLUSTER_NAME="${SPOKE_CLUSTER_TARGET}"
export SPOKE_CLUSTER_NAME

# Auto-detect GPU count from spoke cluster node labels (set by GPU Operator)
GPU_COUNT=$(KUBECONFIG="${TMPKUBE}" oc get nodes -l nvidia.com/gpu.present=true \
  -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
export GPU_COUNT
success "Token obtained — spoke cluster ACM name: ${SPOKE_CLUSTER_NAME}, GPU count: ${GPU_COUNT}"

# ── Step 3: Back on Hub — create ManagedCluster resources ─────────────────────
info "Creating ManagedCluster and ClusterSet on Hub..."
apply_template "${SCRIPT_DIR}/04-managed-spoke-cluster.yaml"
apply_cr       "${SCRIPT_DIR}/05-clusterset.yaml"

wait_for "${SPOKE_CLUSTER_NAME} namespace created by ACM" "oc get namespace ${SPOKE_CLUSTER_NAME}" 120 5

oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: gpuaas-clusterset
  namespace: open-cluster-management
spec:
  clusterSet: gpuaas-clusterset
EOF

# ── Step 4: Create auto-import secret with spoke cluster API URL + token ───────
info "Creating auto-import-secret (server URL + token only)..."
oc create secret generic auto-import-secret \
  --from-literal=autoImportRetry=5 \
  --from-literal=server="${SPOKE_API_URL}" \
  --from-literal=token="${SPOKE_TOKEN}" \
  -n "${SPOKE_CLUSTER_NAME}" \
  --dry-run=client -o yaml | oc apply -f -

oc label secret auto-import-secret -n "${SPOKE_CLUSTER_NAME}" auto-import=cluster --overwrite

success "Auto-import secret created — ACM is installing klusterlet on spoke cluster via API"

# ── Step 5: Wait for spoke cluster to join ─────────────────────────────────────
wait_for "Spoke cluster (${SPOKE_CLUSTER_NAME}) joined ACM Hub" \
  "oc get managedcluster ${SPOKE_CLUSTER_NAME} -o jsonpath='{.status.conditions}' 2>/dev/null | grep -q ManagedClusterJoined" \
  300 15

success "Spoke cluster (${SPOKE_CLUSTER_NAME}) is now managed by ACM Hub!"
echo ""
oc get managedcluster -o wide
echo ""
info "Next: Configure MultiKueue, GPU policy, and ACM Observability"
echo "  bash multi-cluster/02-multikueue/01-multikueue-setup.sh"
