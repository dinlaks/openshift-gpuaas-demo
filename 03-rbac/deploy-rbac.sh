#!/usr/bin/env bash
# Deploy all RBAC resources: users, groups, namespaces, and role bindings.
#
# Usage:
#   bash deploy-rbac.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
load_env
require_oc_login

# ── HTPasswd users and IDP ────────────────────────────────────────────────────
header "HTPasswd users and IDP"

if ! command -v htpasswd &>/dev/null; then
  error "htpasswd not found. Install: dnf install httpd-tools  OR  brew install httpd"
  exit 1
fi

HTPASSWD_FILE=$(mktemp)
trap "rm -f ${HTPASSWD_FILE}" EXIT

htpasswd -c -B -b "${HTPASSWD_FILE}" gpuaas-admin  "${DEMO_PASS_ADMIN}"
htpasswd    -B -b "${HTPASSWD_FILE}" alice           "${DEMO_PASS_ALICE}"
htpasswd    -B -b "${HTPASSWD_FILE}" bob             "${DEMO_PASS_BOB}"
htpasswd    -B -b "${HTPASSWD_FILE}" charlie         "${DEMO_PASS_CHARLIE}"
htpasswd    -B -b "${HTPASSWD_FILE}" diana           "${DEMO_PASS_DIANA}"
htpasswd    -B -b "${HTPASSWD_FILE}" eve             "${DEMO_PASS_EVE}"

oc create secret generic gpuaas-htpasswd \
  --from-file=htpasswd="${HTPASSWD_FILE}" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

oc get oauth cluster -o json | \
  python3 -c "
import sys, json
o = json.load(sys.stdin)
o.setdefault('spec', {}).setdefault('identityProviders', [])
existing = [p for p in o['spec']['identityProviders'] if p.get('name') != 'gpuaas-htpasswd']
existing.append({
  'name': 'gpuaas-htpasswd',
  'mappingMethod': 'claim',
  'type': 'HTPasswd',
  'htpasswd': {'fileData': {'name': 'gpuaas-htpasswd'}}
})
o['spec']['identityProviders'] = existing
print(json.dumps(o))
" | oc apply -f -

success "HTPasswd IDP configured"

# ── Groups, projects, role bindings ──────────────────────────────────────────
header "Groups, projects, and role bindings"
apply_cr "${SCRIPT_DIR}/03-groups.yaml"
apply_cr "${SCRIPT_DIR}/04-rhoai-admin-rbac.yaml"
apply_cr "${SCRIPT_DIR}/05-data-science-projects.yaml"
apply_cr "${SCRIPT_DIR}/06-project-rbac.yaml"
apply_cr "${SCRIPT_DIR}/08-odh-dashboard-config.yaml"

# ── Disable self-provisioner ──────────────────────────────────────────────────
header "Disable self-provisioner (users cannot create namespaces)"
oc patch clusterrolebinding.rbac self-provisioners \
  -p '{"subjects": null}' --type=merge
oc annotate clusterrolebinding.rbac self-provisioners \
  'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite
warn "Only gpuaas-admin can create namespaces now."

# ── RHOAI Auth CR ─────────────────────────────────────────────────────────────
header "RHOAI Auth groups"
bash "${SCRIPT_DIR}/patch-rhoai-auth.sh"

success "RBAC deployed"
