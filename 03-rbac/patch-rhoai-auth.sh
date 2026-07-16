#!/usr/bin/env bash
# Apply RHOAI Auth CR — sets gpuaas-platform-admins as RHOAI dashboard admin group.
#
# In RHOAI 3.3+, the Auth CR (services.platform.opendatahub.io/v1alpha1) controls
# which groups get admin vs user access in the RHOAI dashboard — NOT OdhDashboardConfig.
#
# The RHOAI operator creates the Auth CR with "rhods-admins" as default during
# initialization. This script waits for the operator to settle, then applies our config.
#
# Must run AFTER the RHOAI operator is fully deployed and healthy.
#
# Usage:
#   bash 02-rbac/07-patch-rhoai-auth.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_env
require_oc_login

header "Configuring RHOAI Auth Groups (RHOAI 3.3+)"

info "Waiting for RHOAI operator to settle (30s)..."
sleep 30

wait_for "RHOAI Auth CR exists" \
  "oc get auth auth 2>/dev/null | grep -q auth" \
  120 10

apply_cr "${SCRIPT_DIR}/07-rhoai-auth-groups.yaml"

ADMIN_GROUP=$(oc get auth auth -o jsonpath='{.spec.adminGroups[0]}' 2>/dev/null)
if [[ "${ADMIN_GROUP}" == "gpuaas-platform-admins" ]]; then
  success "RHOAI Auth configured — gpuaas-platform-admins has dashboard admin access"
else
  warn "Auth CR applied but admin group is: ${ADMIN_GROUP} (expected gpuaas-platform-admins)"
fi

info "RHOAI Auth state:"
oc get auth auth -o jsonpath='  adminGroups:   {.spec.adminGroups}{"\n"}  allowedGroups: {.spec.allowedGroups}{"\n"}' 2>&1
