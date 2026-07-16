#!/usr/bin/env bash
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
# Call after load_env. Sets MIG_SMALL_RESOURCE, MIG_LARGE_RESOURCE,
# MIG_SMALL_FLAVOR, MIG_LARGE_FLAVOR, and MIG_PROFILE based on GPU_TYPE.
# These vars are consumed by envsubst when applying YAML templates.
#
# Supported GPU_TYPE values (memory variant must be explicit):
#   a30        — 24 GB  | mig-1g.6gb  / mig-2g.12gb
#   a100-40gb  — 40 GB  | mig-1g.5gb  / mig-2g.10gb
#   a100-80gb  — 80 GB  | mig-1g.10gb / mig-2g.20gb
#   h100-80gb  — 80 GB  | mig-1g.10gb / mig-3g.40gb
#   h100-nvl   — 94 GB  | mig-1g.12gb / mig-3g.47gb
#   h200       — 141 GB | mig-1g.18gb / mig-2g.35gb
#   custom     — you set MIG_SMALL_RESOURCE, MIG_LARGE_RESOURCE etc. in env.sh
#
# Run: oc describe node <gpu-node> | grep nvidia.com/mig   to verify your values.
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
      MIG_PROFILE="${MIG_PROFILE:-mixed-a30}"
      ;;
    a100-40gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.5gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.10gb"
      MIG_SMALL_FLAVOR="a100-40gb-mig-1g5gb"
      MIG_LARGE_FLAVOR="a100-40gb-mig-2g10gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="a100-40gb-full"
      MIG_PROFILE="${MIG_PROFILE:-all-1g.5gb}"
      ;;
    a100-80gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.10gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.20gb"
      MIG_SMALL_FLAVOR="a100-80gb-mig-1g10gb"
      MIG_LARGE_FLAVOR="a100-80gb-mig-2g20gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="a100-80gb-full"
      MIG_PROFILE="${MIG_PROFILE:-all-1g.10gb}"
      ;;
    h100-80gb)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.10gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-3g.40gb"
      MIG_SMALL_FLAVOR="h100-80gb-mig-1g10gb"
      MIG_LARGE_FLAVOR="h100-80gb-mig-3g40gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h100-80gb-full"
      MIG_PROFILE="${MIG_PROFILE:-all-1g.10gb}"
      ;;
    h100-nvl)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.12gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-3g.47gb"
      MIG_SMALL_FLAVOR="h100-nvl-mig-1g12gb"
      MIG_LARGE_FLAVOR="h100-nvl-mig-3g47gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h100-nvl-full"
      MIG_PROFILE="${MIG_PROFILE:-all-1g.12gb}"
      ;;
    h200)
      MIG_SMALL_RESOURCE="nvidia.com/mig-1g.18gb"
      MIG_LARGE_RESOURCE="nvidia.com/mig-2g.35gb"
      MIG_SMALL_FLAVOR="h200-mig-1g18gb"
      MIG_LARGE_FLAVOR="h200-mig-2g35gb"
      FULL_GPU_RESOURCE="nvidia.com/gpu"
      FULL_GPU_FLAVOR="h200-full"
      MIG_PROFILE="${MIG_PROFILE:-all-1g.18gb}"
      ;;
    custom)
      # Validate that the user has set all required variables manually in env.sh
      local missing=()
      for v in MIG_SMALL_RESOURCE MIG_LARGE_RESOURCE MIG_SMALL_FLAVOR MIG_LARGE_FLAVOR \
                FULL_GPU_RESOURCE FULL_GPU_FLAVOR MIG_PROFILE; do
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
         FULL_GPU_RESOURCE FULL_GPU_FLAVOR MIG_PROFILE GPU_TYPE
  info "GPU config resolved: GPU_TYPE=${GPU_TYPE}"
  info "  small slice : ${MIG_SMALL_RESOURCE} (flavor: ${MIG_SMALL_FLAVOR})"
  info "  large slice : ${MIG_LARGE_RESOURCE} (flavor: ${MIG_LARGE_FLAVOR})"
  info "  full GPU    : ${FULL_GPU_RESOURCE} (flavor: ${FULL_GPU_FLAVOR})"
  info "  MIG profile : ${MIG_PROFILE}"
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
