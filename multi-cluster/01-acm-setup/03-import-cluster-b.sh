#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Import Cluster B into ACM Hub using API token — entirely from Cluster A.
# No kubeconfig file, no context switching, no manual steps on Cluster B.
#
# ACM auto-import-secret accepts: server URL + bearer token
# We obtain the token from Cluster B's OAuth API using its admin credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env

[[ -z "${CLUSTER_B_API_URL:-}"           ]] && error "CLUSTER_B_API_URL not set in env.sh" && exit 1
[[ -z "${CLUSTER_B_API_URL_INTERNAL:-}"  ]] && error "CLUSTER_B_API_URL_INTERNAL not set in env.sh" && exit 1
[[ -z "${CLUSTER_B_USERNAME:-}"          ]] && error "CLUSTER_B_USERNAME not set in env.sh" && exit 1
[[ -z "${CLUSTER_B_PASSWORD:-}"          ]] && error "CLUSTER_B_PASSWORD not set in env.sh" && exit 1
[[ -n "${CLUSTER_A_KUBECONFIG:-}" ]] && export KUBECONFIG="${CLUSTER_A_KUBECONFIG}"

# ── Step 1: Stay on Cluster A (Hub) throughout ────────────────────────────────
OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

header "Importing Cluster B via API token — no context switch needed"

# ── Step 2: Obtain a token from Cluster B using a temp kubeconfig ─────────────
# Uses a throwaway KUBECONFIG file so the main oc session (Cluster A) is never touched.
info "Logging into Cluster B to get an API token (temp kubeconfig)..."
TMPKUBE=$(mktemp)
trap "rm -f ${TMPKUBE}" EXIT

KUBECONFIG="${TMPKUBE}" oc login "${CLUSTER_B_API_URL}" \
  -u "${CLUSTER_B_USERNAME}" \
  -p "${CLUSTER_B_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null

CLUSTER_B_TOKEN=$(KUBECONFIG="${TMPKUBE}" oc whoami -t)

if [[ -z "${CLUSTER_B_TOKEN}" ]]; then
  error "Could not obtain token for Cluster B. Check CLUSTER_B_API_URL / credentials in env.sh"
  exit 1
fi
success "Token obtained for Cluster B — main session still on Cluster A"

# ── Step 3: Back on Hub — create ManagedCluster resources ─────────────────────
info "Creating ManagedCluster and ClusterSet on Hub..."
apply_cr "${SCRIPT_DIR}/04-managed-cluster-b.yaml"
apply_cr "${SCRIPT_DIR}/05-clusterset.yaml"

wait_for "cluster-b namespace created by ACM" "oc get namespace cluster-b" 120 5

oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: gpuaas-clusterset
  namespace: open-cluster-management
spec:
  clusterSet: gpuaas-clusterset
EOF

# ── Step 4: Create auto-import secret with Cluster B API URL + token ──────────
# ACM reads this secret, contacts Cluster B's API, installs klusterlet — all from Hub.
info "Creating auto-import-secret (server URL + token only)..."
oc create secret generic auto-import-secret \
  --from-literal=autoImportRetry=5 \
  --from-literal=server="${CLUSTER_B_API_URL_INTERNAL}" \
  --from-literal=token="${CLUSTER_B_TOKEN}" \
  -n cluster-b \
  --dry-run=client -o yaml | oc apply -f -

oc label secret auto-import-secret -n cluster-b auto-import=cluster --overwrite

success "Auto-import secret created — ACM is installing klusterlet on Cluster B via API"

# ── Step 5: Wait for Cluster B to join ────────────────────────────────────────
wait_for "Cluster B joined ACM Hub" \
  "oc get managedcluster cluster-b -o jsonpath='{.status.conditions}' 2>/dev/null | grep -q ManagedClusterJoined" \
  300 15

success "Cluster B (Cluster B) is now managed by ACM Hub on Cluster A!"
echo ""
oc get managedcluster -o wide
echo ""
info "Next: Deploy GPU config to Cluster B"
echo "  bash 00-prereqs/acm/06-deploy-spoke-config.sh"
