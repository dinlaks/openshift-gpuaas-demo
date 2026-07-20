#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Shared functions for all GPUaaS demo scripts — source this file, never duplicate functions.
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n"; }

# ── Environment ───────────────────────────────────────────────────────────────
load_env() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local root_dir="${script_dir%/lib}"

  local env_file="${root_dir}/env.sh"
  if [[ ! -f "${env_file}" ]]; then
    error "env.sh not found at ${env_file}"
    error "Copy env.sh.example to env.sh and fill in your values."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${env_file}"
  info "Loaded env from ${env_file}"

  for var in OCP_API_URL OCP_USERNAME OCP_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      error "Required variable ${var} is not set in env.sh"
      exit 1
    fi
  done
}

# ── OpenShift Login ───────────────────────────────────────────────────────────
require_oc_login() {
  local insecure=""
  [[ -z "${OCP_CA_CERT:-}" ]] && insecure="--insecure-skip-tls-verify=true"

  local current_server current_user
  current_server=$(oc whoami --show-server 2>/dev/null || echo "")
  current_user=$(oc whoami 2>/dev/null || echo "")

  if [[ "${current_server}" != "${OCP_API_URL}" || -z "${current_user}" ]]; then
    info "Logging in to OpenShift at ${OCP_API_URL}..."
    oc login "${OCP_API_URL}" \
      -u "${OCP_USERNAME}" \
      -p "${OCP_PASSWORD}" \
      ${insecure} \
      ${OCP_CA_CERT:+--certificate-authority="${OCP_CA_CERT}"}
  fi
  success "Logged in as $(oc whoami) → $(oc whoami --show-server)"
}

# ── Operator helpers ──────────────────────────────────────────────────────────
ensure_operator() {
  local name="$1" namespace="$2" manifest="$3"
  if oc get subscription "${name}" -n "${namespace}" &>/dev/null; then
    info "Subscription ${name} already exists — skipping"
    return 0
  fi
  info "Installing operator: ${name}"
  apply_cr "${manifest}"
}

wait_operator() {
  local name="$1" namespace="$2" timeout="${3:-300}"
  info "Waiting for operator CSV ${name} in ${namespace} (timeout ${timeout}s)..."
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local phase
    phase=$(oc get csv -n "${namespace}" --no-headers 2>/dev/null \
      | grep -i "^${name}" \
      | awk '{print $NF}' \
      | grep -i 'succeeded' | head -1 || true)
    if [[ -n "${phase}" ]]; then
      success "Operator ${name} ready"
      return 0
    fi
    sleep 10
  done
  error "Operator ${name} did not become ready within ${timeout}s"
  return 1
}

# ── Manifest application ──────────────────────────────────────────────────────
DRY_RUN=${DRY_RUN:-false}

apply_cr() {
  local file="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would apply: ${file}"
    oc apply -f "${file}" --dry-run=client
  else
    oc apply -f "${file}"
  fi
}

apply_dir() {
  local dir="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would apply directory: ${dir}"
    oc apply -f "${dir}" --dry-run=client
  else
    oc apply -f "${dir}"
  fi
}

# ── Generic wait ──────────────────────────────────────────────────────────────
wait_for() {
  local description="$1" check_cmd="$2" timeout="${3:-300}" interval="${4:-10}"
  info "Waiting for: ${description} (timeout ${timeout}s)..."
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if eval "${check_cmd}" &>/dev/null; then
      success "${description} — ready"
      return 0
    fi
    sleep "${interval}"
  done
  error "Timed out waiting for: ${description}"
  return 1
}

# ── GPU config resolution ─────────────────────────────────────────────────────
# Call after load_env. Resolves all GPU resource names, Kueue flavor names,
# MIG profiles per role, and informational labels from GPU_TYPE.
#
# Supported GPU_TYPE values (memory variant must be explicit):
#   a30        — 24 GB  | mig-1g.6gb  / mig-2g.12gb | arch: ampere
#   a100-40gb  — 40 GB  | mig-1g.5gb  / mig-2g.10gb | arch: ampere
#   a100-80gb  — 80 GB  | mig-1g.10gb / mig-2g.20gb | arch: ampere
#   h100-80gb  — 80 GB  | mig-1g.10gb / mig-3g.40gb | arch: hopper
#   h100-nvl   — 94 GB  | mig-1g.12gb / mig-3g.47gb | arch: hopper
#   h200       — 141 GB | mig-1g.18gb / mig-2g.35gb | arch: hopper
#   custom     — set all vars manually in env.sh
#
# Node roles (used by NODE_ROLES and MIG_STRATEGY):
#   small       — all GPUs: uniform small MIG slices (works with 1+ GPUs)
#   large       — all GPUs: uniform large MIG slices (works with 1+ GPUs)
#   dedicated   — all GPUs: full GPU, no MIG (works with 1+ GPUs)
#   mixed       — GPU 0: small MIG, GPU 1: small+large MIG (requires 2+ GPUs)
#   full-combo  — GPU 0: small MIG, GPU 1: full non-MIG GPU (requires 2+ GPUs)
#
# Run: bash 02-gpu-setup/05-validation/validate-nodes.sh  to inspect labels.
resolve_gpu_config() {
  local gpu="${GPU_TYPE:-a30}"
  case "${gpu}" in
    a30)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.6gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.12gb"
      MIG_SMALL_FLAVOR="a30-mig-1g6gb"
      MIG_LARGE_FLAVOR="a30-mig-2g12gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="a30-full"
      MIG_PROFILE_SMALL="all-1g.6gb"
      MIG_PROFILE_LARGE="all-2g.12gb"
      MIG_PROFILE_MIXED="mixed-a30"
      MIG_PROFILE_FULL_COMBO="full-combo-a30"
      GPU_MEMORY="24gb"
      GPU_ARCH="ampere"
      ;;
    a100-40gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.5gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.10gb"
      MIG_SMALL_FLAVOR="a100-40gb-mig-1g5gb"
      MIG_LARGE_FLAVOR="a100-40gb-mig-2g10gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="a100-40gb-full"
      MIG_PROFILE_SMALL="all-1g.5gb"
      MIG_PROFILE_LARGE="all-2g.10gb"
      MIG_PROFILE_MIXED="mixed-a100-40gb"
      MIG_PROFILE_FULL_COMBO="full-combo-a100-40gb"
      GPU_MEMORY="40gb"
      GPU_ARCH="ampere"
      ;;
    a100-80gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.10gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.20gb"
      MIG_SMALL_FLAVOR="a100-80gb-mig-1g10gb"
      MIG_LARGE_FLAVOR="a100-80gb-mig-2g20gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="a100-80gb-full"
      MIG_PROFILE_SMALL="all-1g.10gb"
      MIG_PROFILE_LARGE="all-2g.20gb"
      MIG_PROFILE_MIXED="mixed-a100-80gb"
      MIG_PROFILE_FULL_COMBO="full-combo-a100-80gb"
      GPU_MEMORY="80gb"
      GPU_ARCH="ampere"
      ;;
    h100-80gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.10gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-3g.40gb"
      MIG_SMALL_FLAVOR="h100-80gb-mig-1g10gb"
      MIG_LARGE_FLAVOR="h100-80gb-mig-3g40gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h100-80gb-full"
      MIG_PROFILE_SMALL="all-1g.10gb"
      MIG_PROFILE_LARGE="all-3g.40gb"
      MIG_PROFILE_MIXED="mixed-h100-80gb"
      MIG_PROFILE_FULL_COMBO="full-combo-h100-80gb"
      GPU_MEMORY="80gb"
      GPU_ARCH="hopper"
      ;;
    h100-nvl)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.12gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-3g.47gb"
      MIG_SMALL_FLAVOR="h100-nvl-mig-1g12gb"
      MIG_LARGE_FLAVOR="h100-nvl-mig-3g47gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h100-nvl-full"
      MIG_PROFILE_SMALL="all-1g.12gb"
      MIG_PROFILE_LARGE="all-3g.47gb"
      MIG_PROFILE_MIXED="mixed-h100-nvl"
      MIG_PROFILE_FULL_COMBO="full-combo-h100-nvl"
      GPU_MEMORY="94gb"
      GPU_ARCH="hopper"
      ;;
    h200)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.18gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.35gb"
      MIG_SMALL_FLAVOR="h200-mig-1g18gb"
      MIG_LARGE_FLAVOR="h200-mig-2g35gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h200-full"
      MIG_PROFILE_SMALL="all-1g.18gb"
      MIG_PROFILE_LARGE="all-2g.35gb"
      MIG_PROFILE_MIXED="mixed-h200"
      MIG_PROFILE_FULL_COMBO="full-combo-h200"
      GPU_MEMORY="141gb"
      GPU_ARCH="hopper"
      ;;
    custom)
      local missing=()
      for v in MIG_SMALL_RESOURCE MIG_LARGE_RESOURCE MIG_SMALL_FLAVOR MIG_LARGE_FLAVOR \
                FULL_GPU_RESOURCE FULL_GPU_FLAVOR \
                MIG_PROFILE_SMALL MIG_PROFILE_LARGE MIG_PROFILE_MIXED MIG_PROFILE_FULL_COMBO \
                GPU_MEMORY GPU_ARCH; do
        [[ -z "${!v:-}" ]] && missing+=("${v}")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        error "GPU_TYPE=custom requires these variables to be set in env.sh:"
        for v in "${missing[@]}"; do error "  ${v}"; done
        error "See env.sh.example for the custom GPU_TYPE section."
        exit 1
      fi
      ;;
    *)
      error "Unknown GPU_TYPE: '${gpu}'"
      error "Valid values: a30 | a100-40gb | a100-80gb | h100-80gb | h100-nvl | h200 | custom"
      error "Tip: run  oc describe node <gpu-node> | grep nvidia.com/mig  to see your resource names."
      exit 1
      ;;
  esac
  export MIG_SMALL_RESOURCE MIG_LARGE_RESOURCE MIG_SMALL_FLAVOR MIG_LARGE_FLAVOR \
         FULL_GPU_RESOURCE FULL_GPU_FLAVOR GPU_TYPE \
         MIG_PROFILE_SMALL MIG_PROFILE_LARGE MIG_PROFILE_MIXED MIG_PROFILE_FULL_COMBO \
         GPU_MEMORY GPU_ARCH
  info "GPU config resolved: GPU_TYPE=${GPU_TYPE} (${GPU_MEMORY}, arch=${GPU_ARCH})"
  info "  small : ${MIG_SMALL_RESOURCE}  large : ${MIG_LARGE_RESOURCE}  full : ${FULL_GPU_RESOURCE}"
}

# Return the mig-parted profile name for a given node role.
# Usage: profile=$(get_profile_for_role "small")
get_profile_for_role() {
  local role="$1"
  case "${role}" in
    small)      echo "${MIG_PROFILE_SMALL}" ;;
    large)      echo "${MIG_PROFILE_LARGE}" ;;
    mixed)      echo "${MIG_PROFILE_MIXED}" ;;
    full-combo) echo "${MIG_PROFILE_FULL_COMBO}" ;;
    dedicated)  echo "" ;;   # no MIG — mig-enabled: false on all GPUs
    *)
      error "Unknown node role: '${role}'"
      error "Valid roles: small | large | dedicated | mixed | full-combo"
      exit 1
      ;;
  esac
}

# Apply capability labels to a node for a given role.
# Sets demo/gpu-has-small-mig, demo/gpu-has-large-mig, demo/gpu-has-full as appropriate.
# Usage: label_node_capabilities "worker-gpu-0" "mixed"
label_node_capabilities() {
  local node="$1" role="$2"

  # Clear all capability labels first so stale labels don't remain
  oc label node "${node}" \
    demo/gpu-type="${GPU_TYPE}" \
    demo/gpu-memory="${GPU_MEMORY}" \
    demo/gpu-arch="${GPU_ARCH}" \
    demo/gpu-role="${role}" \
    demo/gpu-has-small-mig- \
    demo/gpu-has-large-mig- \
    demo/gpu-has-full- \
    --overwrite 2>/dev/null || true

  case "${role}" in
    small)
      oc label node "${node}" demo/gpu-has-small-mig=true --overwrite ;;
    large)
      oc label node "${node}" demo/gpu-has-large-mig=true --overwrite ;;
    dedicated)
      oc label node "${node}" demo/gpu-has-full=true --overwrite ;;
    mixed)
      oc label node "${node}" \
        demo/gpu-has-small-mig=true \
        demo/gpu-has-large-mig=true --overwrite ;;
    full-combo)
      oc label node "${node}" \
        demo/gpu-has-small-mig=true \
        demo/gpu-has-full=true --overwrite ;;
  esac
  success "Labelled ${node}: role=${role} (gpu-type=${GPU_TYPE}, memory=${GPU_MEMORY})"
}

# Apply a YAML template — substitutes GPU resource vars before applying.
# Use for any YAML that contains ${MIG_SMALL_RESOURCE} etc.
apply_template() {
  local file="$1"
  local vars='${GPU_TYPE}${MIG_SMALL_RESOURCE}${MIG_LARGE_RESOURCE}${MIG_SMALL_FLAVOR}${MIG_LARGE_FLAVOR}${FULL_GPU_RESOURCE}${FULL_GPU_FLAVOR}'
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would apply template: ${file}"
    envsubst "${vars}" < "${file}" | oc apply -f - --dry-run=client
  else
    envsubst "${vars}" < "${file}" | oc apply -f -
  fi
}

# ── Node helpers ──────────────────────────────────────────────────────────────
get_gpu_nodes() {
  oc get nodes -l nvidia.com/gpu.present=true -o name | sed 's|node/||'
}

label_node() {
  local node="$1" label="$2"
  oc label node "${node}" "${label}" --overwrite
  success "Labelled ${node}: ${label}"
}
