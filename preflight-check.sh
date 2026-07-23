#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Pre-flight validation — runs ALL checks and prints a full error list at the end.
# No abrupt exits mid-run — every check runs regardless of previous failures.
#
# Usage:
#   bash preflight-check.sh              # single-cluster checks
#   bash preflight-check.sh --multi      # also validate Cluster B + ACM
set -uo pipefail   # -u: catch unset vars; NO -e so all checks always run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

MULTI=false
[[ "${1:-}" == "--multi" ]] && MULTI=true

# ── Error/warning tracking ────────────────────────────────────────────────────
ERRORS=()
WARNINGS=()

fail()    { ERRORS+=("✗ $*");    error "$*"; }
warn_pre(){ WARNINGS+=("⚠ $*"); warn  "$*"; }
pass()    { success "$*"; }

load_env || { echo "ERROR: Could not load env.sh — cannot continue pre-flight."; exit 1; }

# ── 1. Required env.sh variables ─────────────────────────────────────────────
header "1. Required env.sh variables"

for var in OCP_API_URL OCP_USERNAME OCP_PASSWORD GPU_TYPE MIG_STRATEGY \
           RHOAI_CHANNEL KUEUE_CHANNEL \
           DEMO_PASS_ADMIN DEMO_PASS_ALICE DEMO_PASS_BOB \
           DEMO_PASS_CHARLIE DEMO_PASS_DIANA DEMO_PASS_EVE; do
  if [[ -z "${!var:-}" ]]; then
    fail "Variable '${var}' is not set in env.sh"
  else
    pass "${var} = ${!var}"
  fi
done

VALID_GPU_TYPES="a30 a100-40gb a100-80gb h100-80gb h100-nvl h200 custom"
if [[ -n "${GPU_TYPE:-}" ]] && ! echo "${VALID_GPU_TYPES}" | tr ' ' '\n' | grep -q "^${GPU_TYPE}$"; then
  fail "GPU_TYPE='${GPU_TYPE}' invalid. Valid: ${VALID_GPU_TYPES}"
fi

VALID_STRATEGIES="small large dedicated mixed full-combo"
if [[ -n "${MIG_STRATEGY:-}" ]] && ! echo "${VALID_STRATEGIES}" | tr ' ' '\n' | grep -q "^${MIG_STRATEGY}$"; then
  fail "MIG_STRATEGY='${MIG_STRATEGY}' invalid. Valid: ${VALID_STRATEGIES}"
fi

# ── 2. Required CLI tools ─────────────────────────────────────────────────────
header "2. Required CLI tools"

for tool in oc python3 htpasswd; do
  if command -v "${tool}" &>/dev/null; then
    pass "${tool}: $(command -v ${tool})"
  else
    fail "'${tool}' not found — install before running setup"
  fi
done
if command -v helm &>/dev/null; then
  pass "helm: $(command -v helm) (needed for UC2 DRA)"
else
  warn_pre "helm not found — only required for UC2 DRA demo"
fi

# ── 3. Cluster reachability ───────────────────────────────────────────────────
header "3. Cluster reachability"

CLUSTER_OK=false
if [[ -n "${OCP_API_URL:-}" && -n "${OCP_USERNAME:-}" && -n "${OCP_PASSWORD:-}" ]]; then
  if oc login "${OCP_API_URL}" -u "${OCP_USERNAME}" -p "${OCP_PASSWORD}" \
      --insecure-skip-tls-verify=true &>/dev/null 2>&1; then
    pass "Cluster reachable: $(oc whoami 2>/dev/null) @ $(oc whoami --show-server 2>/dev/null)"
    CLUSTER_OK=true
  else
    fail "Cannot log in to ${OCP_API_URL} — check OCP_API_URL, OCP_USERNAME, OCP_PASSWORD"
  fi
else
  fail "OCP connection variables not set — skipping cluster checks"
fi

# ── 4. OCP version ────────────────────────────────────────────────────────────
header "4. OCP version"

if [[ "${CLUSTER_OK}" == "true" ]]; then
  OCP_VERSION=$(oc version -o json 2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('openshiftVersion','unknown'))" \
    2>/dev/null || echo "unknown")
  if [[ "${OCP_VERSION}" == "unknown" ]]; then
    warn_pre "Could not determine OCP version"
  else
    MINOR=$(echo "${OCP_VERSION}" | cut -d. -f2 || echo "0")
    if (( MINOR < 17 )); then
      fail "OCP 4.17+ required — found ${OCP_VERSION}"
    elif (( MINOR < 21 )); then
      pass "OCP version: ${OCP_VERSION} (DRA/UC2 requires 4.21+, all other UCs will work)"
    else
      pass "OCP version: ${OCP_VERSION} — all features including DRA supported"
    fi
  fi
else
  warn_pre "Skipping OCP version check — cluster not reachable"
fi

# ── 5. GPU nodes ──────────────────────────────────────────────────────────────
header "5. GPU nodes"

if [[ "${CLUSTER_OK}" == "true" ]]; then
  GPU_NODE_COUNT=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if (( GPU_NODE_COUNT == 0 )); then
    warn_pre "No GPU nodes found (nvidia.com/gpu.present=true) — expected on fresh install before NFD and GPU Operator are deployed"
  else
    pass "${GPU_NODE_COUNT} GPU node(s) found:"
    oc get nodes -l nvidia.com/gpu.present=true \
      -o custom-columns='  NODE:.metadata.name,STATUS:.status.conditions[-1].type' \
      --no-headers 2>/dev/null || true
  fi
else
  warn_pre "Skipping GPU node check — cluster not reachable"
fi

# ── 6. NODE_ROLES node name validation ────────────────────────────────────────
header "6. NODE_ROLES validation"

if [[ "${CLUSTER_OK}" == "true" && ${#NODE_ROLES[@]} -gt 0 ]]; then
  VALID_ROLES="small large dedicated mixed full-combo"
  for entry in "${NODE_ROLES[@]}"; do
    [[ -z "${entry}" ]] && continue
    node="${entry%%:*}"
    role="${entry##*:}"
    if ! oc get node "${node}" &>/dev/null 2>&1; then
      fail "NODE_ROLES: node '${node}' not found in cluster"
      info "  Available GPU nodes: $(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | sed 's|node/||' | tr '\n' ' ')"
    else
      if ! echo "${VALID_ROLES}" | tr ' ' '\n' | grep -q "^${role}$"; then
        fail "NODE_ROLES: role '${role}' for '${node}' invalid. Valid: ${VALID_ROLES}"
      else
        pass "NODE_ROLES: ${node} → ${role}"
      fi
    fi
  done
else
  if [[ "${CLUSTER_OK}" == "true" ]]; then
    pass "NODE_ROLES not set — MIG_STRATEGY='${MIG_STRATEGY:-small}' applies to all GPU nodes"
  else
    warn_pre "Skipping NODE_ROLES check — cluster not reachable"
  fi
fi

# ── 7. Operator channel availability ─────────────────────────────────────────
header "7. Operator channels"

if [[ "${CLUSTER_OK}" == "true" ]]; then
  check_channel_pre() {
    local pkg="$1" channel="$2"
    local available
    available=$(oc get packagemanifest "${pkg}" -n openshift-marketplace \
      -o jsonpath='{.status.channels[*].name}' 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' || echo "")
    if [[ -z "${available}" ]]; then
      fail "PackageManifest '${pkg}' not found — OperatorHub may not be configured"
    elif ! echo "${available}" | tr ' ' '\n' | grep -q "^${channel}$"; then
      fail "'${pkg}': channel '${channel}' not found. Available: ${available}"
    else
      pass "${pkg}: channel '${channel}' ✓"
    fi
  }

  check_channel_pre "rhods-operator"  "${RHOAI_CHANNEL:-stable-3.4}"
  check_channel_pre "kueue-operator"  "${KUEUE_CHANNEL:-stable-v1.4}"
  check_channel_pre "gpu-operator-certified"   "v24.9"
  check_channel_pre "nfd"                      "stable"
  check_channel_pre "openshift-cert-manager-operator" "stable-v1"
else
  warn_pre "Skipping operator channel checks — cluster not reachable"
fi

# ── 8. Default StorageClass ───────────────────────────────────────────────────
header "8. Storage"

if [[ "${CLUSTER_OK}" == "true" ]]; then
  DEFAULT_SC=$(oc get storageclass \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
    2>/dev/null || echo "")
  if [[ -z "${DEFAULT_SC}" ]]; then
    fail "No default StorageClass — RHOAI PVCs will fail without one"
    info "  Fix: bash optional/storage/deploy-storage.sh --lvm  (bare-metal)"
    info "       OR mark an existing StorageClass as default"
  else
    pass "Default StorageClass: ${DEFAULT_SC}"
  fi
else
  warn_pre "Skipping StorageClass check — cluster not reachable"
fi

# ── 9. Multi-cluster checks (--multi flag only) ───────────────────────────────
if [[ "${MULTI}" == "true" ]]; then
  header "9. Multi-cluster (Cluster A + B)"

  for var in CLUSTER_A_API_URL CLUSTER_A_USERNAME CLUSTER_A_PASSWORD \
             SPOKE_CLUSTER_API_URL SPOKE_CLUSTER_USERNAME SPOKE_CLUSTER_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      fail "Multi-cluster: '${var}' not set in env.sh"
    else
      pass "${var} set"
    fi
  done

  # Cluster A
  if [[ -n "${CLUSTER_A_API_URL:-}" ]]; then
    if oc login "${CLUSTER_A_API_URL}" -u "${CLUSTER_A_USERNAME:-}" -p "${CLUSTER_A_PASSWORD:-}" \
        --insecure-skip-tls-verify=true &>/dev/null 2>&1; then
      pass "Cluster A reachable: $(oc whoami --show-server 2>/dev/null)"

      if oc get multiclusterhub -A --no-headers 2>/dev/null | grep -q .; then
        pass "ACM Hub installed on Cluster A"
      else
        fail "ACM Hub not found on Cluster A — run: bash multi-cluster/01-acm-setup/01-install-hub.sh"
      fi

      B_NAME=$(resolve_cluster_b_name 2>/dev/null || echo "cluster-b")
      if oc get managedcluster "${B_NAME}" --no-headers 2>/dev/null | grep -q .; then
        pass "Cluster B imported into ACM as '${B_NAME}'"
      else
        fail "Cluster B not imported into ACM — run: bash multi-cluster/01-acm-setup/03-import-cluster-b.sh"
      fi
    else
      fail "Cannot reach Cluster A at ${CLUSTER_A_API_URL}"
    fi
  fi

  # Cluster B
  if [[ -n "${SPOKE_CLUSTER_API_URL:-}" ]]; then
    if oc login "${SPOKE_CLUSTER_API_URL}" -u "${SPOKE_CLUSTER_USERNAME:-}" -p "${SPOKE_CLUSTER_PASSWORD:-}" \
        --insecure-skip-tls-verify=true &>/dev/null 2>&1; then
      pass "Cluster B reachable: $(oc whoami --show-server 2>/dev/null)"
    else
      fail "Cannot reach Cluster B at ${SPOKE_CLUSTER_API_URL}"
    fi
  fi

  # Switch back to Cluster A if possible
  if [[ -n "${CLUSTER_A_API_URL:-}" ]]; then
    oc login "${CLUSTER_A_API_URL}" -u "${CLUSTER_A_USERNAME:-}" -p "${CLUSTER_A_PASSWORD:-}" \
      --insecure-skip-tls-verify=true &>/dev/null 2>&1 || true
  fi

  # MinIO
  if [[ -n "${MINIO_ENDPOINT:-}" ]]; then
    if curl -sf --max-time 5 "${MINIO_ENDPOINT}/minio/health/ready" &>/dev/null 2>&1; then
      pass "MinIO reachable at ${MINIO_ENDPOINT}"
    else
      fail "MinIO not reachable at ${MINIO_ENDPOINT} — run: bash optional/storage/deploy-storage.sh --minio"
    fi
  else
    warn_pre "MINIO_ENDPOINT not set — ACM Observability requires object storage"
  fi
fi

# ── Final result ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"

if (( ${#WARNINGS[@]} > 0 )); then
  echo ""
  warn "Warnings (${#WARNINGS[@]}) — non-blocking, review before setup:"
  for w in "${WARNINGS[@]}"; do
    echo "  ${w}"
  done
fi

if (( ${#ERRORS[@]} > 0 )); then
  echo ""
  error "Pre-flight FAILED — ${#ERRORS[@]} error(s) must be fixed before running setup:"
  for e in "${ERRORS[@]}"; do
    echo "  ${e}"
  done
  echo ""
  exit 1
else
  echo ""
  success "All pre-flight checks passed!"
  echo ""
  if [[ "${MULTI}" == "true" ]]; then
    info "Ready to run:  bash multi-cluster/02-multikueue/01-multikueue-setup.sh"
  else
    info "Ready to run:  bash setup.sh"
  fi
fi
