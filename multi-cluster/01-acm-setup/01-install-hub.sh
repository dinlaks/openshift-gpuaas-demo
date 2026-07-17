#!/usr/bin/env bash
# Install ACM Hub on Cluster A (Cluster A) — run ONCE after deploy-prereqs.sh.
# ACM operator is installed first; MultiClusterHub then pulls in MCE automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
load_env

[[ -z "${CLUSTER_A_KUBECONFIG:-}" ]] && error "CLUSTER_A_KUBECONFIG not set in env.sh" && exit 1
export KUBECONFIG="${CLUSTER_A_KUBECONFIG}"

OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

header "Installing ACM Hub on Cluster A"

# ── Namespace ─────────────────────────────────────────────────────────────────
if oc get namespace open-cluster-management &>/dev/null; then
  info "Namespace open-cluster-management already exists — skipping"
else
  oc create namespace open-cluster-management
fi

# ── ACM operator ──────────────────────────────────────────────────────────────
if oc get subscription advanced-cluster-management -n open-cluster-management &>/dev/null; then
  info "Subscription advanced-cluster-management already exists — skipping"
else
  info "Installing ACM operator..."
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management-operatorgroup
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.16
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
fi

wait_operator advanced-cluster-management open-cluster-management 600

# ── MultiClusterHub (MCE installed automatically as dependency) ───────────────
wait_for "MultiClusterHub CRD registered" \
  "oc get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null" 180 10

if oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null; then
  info "MultiClusterHub already exists — skipping"
else
  apply_cr "${SCRIPT_DIR}/02-multiclusterhub.yaml"
fi

wait_for "MultiClusterHub running (MCE installs in background — up to 10 min)" \
  "oc get multiclusterhub multiclusterhub -n open-cluster-management \
    -o jsonpath='{.status.phase}' 2>/dev/null | grep -qi running" 600 20

success "ACM Hub deployed on Cluster A"
echo ""
info "Next: Register Cluster B as a spoke"
echo "  bash 00-prereqs/acm/03-import-cluster-b.sh"
