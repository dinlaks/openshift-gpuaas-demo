#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Configure MultiKueue using ACM ManagedServiceAccount — fully ACM-managed.
# No manual token generation, no context switching, no kubeconfig files.
#
# How it works:
#   1. Enable ManagedServiceAccount addon on ACM Hub
#   2. Create ManagedServiceAccount on Hub (in cluster-b namespace)
#      → ACM creates SA on Cluster B AND syncs token back to Hub as a Secret
#   3. ConfigurationPolicy on Hub creates MultiKueueCluster pointing to that secret
#      → Kueue can now reach Cluster B automatically
#
# When you add a 3rd cluster to ACM: repeat step 2 for that cluster.
# ACM handles token creation, rotation, and sync. Zero manual token management.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env
resolve_gpu_config   # needed for apply_template on global ClusterQueue

# Auto-detect Cluster B's infrastructure name for ACM ManagedCluster name
CLUSTER_B_NAME=$(resolve_cluster_b_name)
export CLUSTER_B_NAME
info "Cluster B ACM name: ${CLUSTER_B_NAME}"

OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

header "Configuring MultiKueue via ACM ManagedServiceAccount"

# ── Step 1: Enable ManagedServiceAccount addon on ACM Hub ─────────────────────
info "Enabling ManagedServiceAccount addon..."
oc apply -f - <<EOF
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: managed-serviceaccount
  namespace: ${CLUSTER_B_NAME}
spec:
  installNamespace: open-cluster-management-agent-addon
EOF

wait_for "ManagedServiceAccount addon available on ${CLUSTER_B_NAME}" \
  "oc get managedclusteraddon managed-serviceaccount -n "${CLUSTER_B_NAME}" \
   -o jsonpath='{.status.conditions}' | grep -q Available" \
  120 10
success "ManagedServiceAccount addon ready"

# ── Step 2: Create ManagedServiceAccount — ACM handles everything ──────────────
# ACM will:
#   a) Create multikueue-worker SA on Cluster B
#   b) Bind it to cluster-admin (via our GPU Policy)
#   c) Generate a token and sync it back to Hub as Secret in cluster-b namespace
info "Creating ManagedServiceAccount for MultiKueue on ${CLUSTER_B_NAME}..."
apply_template "${SCRIPT_DIR}/00-managed-serviceaccount.yaml"

wait_for "Token synced to Hub from ${CLUSTER_B_NAME}" \
  "oc get secret multikueue-worker -n "${CLUSTER_B_NAME}" 2>/dev/null | grep -q multikueue-worker" \
  120 10
success "Token synced to Hub — secret 'multikueue-worker' in namespace '${CLUSTER_B_NAME}'"

# ── Step 3: Build MultiKueue kubeconfig from the ACM-synced secret ────────────
# ACM synced the token. Now assemble it into a kubeconfig for MultiKueue.
info "Building MultiKueue kubeconfig from ACM-synced token..."

TOKEN=$(oc get secret multikueue-worker -n "${CLUSTER_B_NAME}" \
  -o jsonpath='{.data.token}' | base64 -d)

# Get the real cluster-b API URL from ACM ManagedCluster (not CLUSTER_B_API_URL which may
# be a local tunnel). Kueue controller runs inside the cluster and needs the routable URL.
CLUSTER_B_REAL_URL=$(oc get managedcluster ${CLUSTER_B_NAME} \
  -o jsonpath='{.spec.managedClusterClientConfigs[0].url}' 2>/dev/null)

# Get CA from cluster-b's kube-root-ca.crt (the ACM token ca.crt is not parseable as PEM by Kueue)
info "Fetching ${CLUSTER_B_NAME} CA from kube-root-ca.crt..."
oc login "${CLUSTER_B_REAL_URL}" -u "${SPOKE_CLUSTER_USERNAME}" -p "${SPOKE_CLUSTER_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null || \
  oc login "${CLUSTER_B_API_URL}" -u "${SPOKE_CLUSTER_USERNAME}" -p "${SPOKE_CLUSTER_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null
CA_DATA=$(oc get configmap kube-root-ca.crt -n default \
  -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')
# Switch back to cluster-a
oc login "${CLUSTER_A_API_URL}" -u "${CLUSTER_A_USERNAME}" -p "${CLUSTER_A_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null

# Create secret in openshift-kueue-operator namespace where the Kueue controller can find it.
# Note: Kueue controller looks for the secret in its own namespace (openshift-kueue-operator),
# NOT in redhat-ods-applications.
oc create secret generic multikueue-${CLUSTER_B_NAME}-kubeconfig \
  -n openshift-kueue-operator \
  --dry-run=client -o yaml \
  --from-literal=kubeconfig="$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_B_NAME}
    cluster:
      server: ${CLUSTER_B_REAL_URL:-${CLUSTER_B_API_URL}}
      certificate-authority-data: ${CA_DATA}
contexts:
  - name: ${CLUSTER_B_NAME}
    context:
      cluster: ${CLUSTER_B_NAME}
      user: multikueue-worker
current-context: ${CLUSTER_B_NAME}
users:
  - name: multikueue-worker
    user:
      token: ${TOKEN}
EOF
)" | oc apply -f -

# ── Step 4: Apply MultiKueue resources ────────────────────────────────────────
info "Applying MultiKueue config, cluster, admission check, and global queue..."
apply_template "${SCRIPT_DIR}/02-multikueue-config.yaml"
apply_template "${SCRIPT_DIR}/03-multikueue-cluster.yaml"
apply_cr      "${SCRIPT_DIR}/04-admission-check.yaml"
apply_template "${SCRIPT_DIR}/05-global-gpu-clusterqueue.yaml"   # contains ${MIG_*} vars
apply_cr      "${SCRIPT_DIR}/06-global-gpu-localqueues.yaml"

# ── Step 5: Apply ACM GPU Policy and binding ───────────────────────────────────
# Enforces GPU Operator subscription, MIG config, and Kueue ResourceFlavors
# across all managed clusters in the fleet. Applied on Hub, propagated to spokes.
info "Applying ACM GPU fleet governance policy..."
apply_template "${SCRIPT_DIR}/../01-acm-setup/08-acm-gpu-policy.yaml"
apply_cr      "${SCRIPT_DIR}/../01-acm-setup/09-acm-policy-binding.yaml"
success "ACM GPU policy applied — fleet governance active"

# On re-runs, restart governance-policy-framework on cluster-b if present to force
# a clean status re-sync after policy propagation.
info "Waiting 20s for policy propagation to ${CLUSTER_B_NAME}..."
sleep 20

oc login "${CLUSTER_B_REAL_URL:-${CLUSTER_B_API_URL}}" \
  -u "${SPOKE_CLUSTER_USERNAME}" -p "${SPOKE_CLUSTER_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null
GOV_PODS=$(oc get pods -n open-cluster-management-agent-addon \
  -l app=governance-policy-framework --no-headers 2>/dev/null | wc -l | tr -d ' ')
if (( GOV_PODS > 0 )); then
  info "Restarting governance-policy-framework on ${CLUSTER_B_NAME}..."
  oc delete pod -n open-cluster-management-agent-addon \
    -l app=governance-policy-framework --ignore-not-found
  wait_for "governance-policy-framework restarted" \
    "oc get pods -n open-cluster-management-agent-addon -l app=governance-policy-framework \
     --no-headers 2>/dev/null | grep -q Running" \
    60 5 || warn "governance-policy-framework restart timed out — continuing"
  success "governance-policy-framework restarted"
else
  info "governance-policy-framework not present on ${CLUSTER_B_NAME} — skipping restart"
fi

# Switch back to cluster-a hub
oc login "${CLUSTER_A_API_URL}" \
  -u "${CLUSTER_A_USERNAME}" -p "${CLUSTER_A_PASSWORD}" \
  --insecure-skip-tls-verify=true 2>/dev/null

wait_for "Policy compliant on ${CLUSTER_B_NAME}" \
  "oc get policy gpuaas-gpu-config-policy -n open-cluster-management \
   -o jsonpath='{.status.compliant}' 2>/dev/null | grep -q Compliant" \
  180 15 || warn "Policy not yet compliant — check 'oc get policy gpuaas-gpu-config-policy -n open-cluster-management'"

# ── Step 6: Apply ACM Observability ───────────────────────────────────────────
# Enables Thanos + Grafana on Hub to collect DCGM GPU metrics from both clusters.
# Requires MinIO to be running — deploy first if not already:
#   bash optional/storage/deploy-storage.sh --minio
info "Applying ACM Observability (Thanos + Grafana → MinIO) ..."
apply_cr "${SCRIPT_DIR}/../03-acm-observability/10-acm-observability.yaml"
success "ACM Observability applied"

# Deploy DCGM MIG GPU dashboard — ACM Grafana auto-discovers ConfigMaps with grafana-dashboard- prefix
info "Deploying DCGM MIG GPU Grafana dashboard..."
if [[ -f "${SCRIPT_DIR}/../03-acm-observability/grafana-dcgm-mig-dashboard.json" ]]; then
  oc create configmap grafana-dashboard-dcgm-mig-gpu \
    -n open-cluster-management-observability \
    --from-file=dcgm-mig-dashboard.json="${SCRIPT_DIR}/../03-acm-observability/grafana-dcgm-mig-dashboard.json" \
    --dry-run=client -o yaml | oc apply -f - 2>/dev/null
  success "DCGM MIG GPU dashboard deployed — visible in Grafana → Dashboards → Browse"
else
  warn "grafana-dcgm-mig-dashboard.json not found — download from https://grafana.com/api/dashboards/23382/revisions/latest/download"
fi

wait_for "MultiClusterObservability Ready" \
  "oc get multiclusterobservability observability \
   -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True" \
  300 20 || warn "Observability not yet Ready — check 'oc get multiclusterobservability'"

success "MultiKueue + ACM fully configured!"
echo ""
info "ACM ManagedServiceAccount handles token rotation automatically."
info "No manual token refresh needed — ACM keeps the secret current."
echo ""
info "Verify:"
echo "  oc get managedserviceaccount multikueue-worker -n "${CLUSTER_B_NAME}""
echo "  oc get multikueuecluster ${CLUSTER_B_NAME}"
echo "  oc get policy gpuaas-gpu-config-policy -n open-cluster-management"
echo "  oc get clusterqueue global-gpu-queue"
echo "  oc get multiclusterobservability observability"
