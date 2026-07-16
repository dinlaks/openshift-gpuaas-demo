#!/usr/bin/env bash
# GPUaaS Demo Cleanup — remove demo workloads between use cases or for a full reset
#
# Usage:
#   bash cleanup.sh uc3          # clean only UC3 workloads
#   bash cleanup.sh uc4 uc5      # clean multiple UCs
#   bash cleanup.sh all          # full reset — all demo workloads
#   bash cleanup.sh all --hard   # also remove Kueue queues and hardware profiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env
require_oc_login

TARGETS=("$@")
HARD=false
[[ " ${TARGETS[*]} " =~ " --hard " ]] && HARD=true
TARGETS=(${TARGETS[@]/--hard/})

NAMESPACES="inference-team-project ds-team-project research-team-project finetune-team-project analytics-project gpuaas-system"

delete_by_label() {
  local uc_label="$1"
  info "Cleaning workloads labelled demo/uc=${uc_label}..."
  for ns in ${NAMESPACES}; do
    oc delete job,pod -n "$ns" -l "demo/uc=${uc_label}" --ignore-not-found 2>/dev/null || true
    oc delete workload -n "$ns" -l "kueue.x-k8s.io/job-uid" --ignore-not-found 2>/dev/null || true
  done
  success "UC ${uc_label} workloads removed"
}

clean_uc2() {
  delete_by_label uc2-dra
  oc delete resourceclaim -A -l "demo/uc=uc2-dra" --ignore-not-found 2>/dev/null || true
}
clean_uc3()  { delete_by_label uc3-quota; }
clean_uc4()  { delete_by_label uc4-queue-scheduling; }
clean_uc5()  { delete_by_label uc5-priority; }
clean_uc6()  { delete_by_label uc6-placement; }
clean_uc7()  { delete_by_label uc7-multi-cluster; delete_by_label uc7-filler; }
clean_uc8()  { delete_by_label uc8-gang; }
clean_uc9() {
  info "Restoring default quota on inference-cluster-queue..."
  oc patch clusterqueue inference-cluster-queue --type=merge \
    -p '{"spec":{"stopPolicy":"None"}}' 2>/dev/null || true
  delete_by_label uc9-time-based
  oc delete cronjob gpuaas-weekend-policy gpuaas-weekday-policy \
    -n gpuaas-system --ignore-not-found 2>/dev/null || true
  success "UC9: CronJobs removed, queue restored"
}

if [[ " ${TARGETS[*]} " =~ " all " ]]; then
  header "Full demo cleanup"
  clean_uc2; clean_uc3; clean_uc4; clean_uc5; clean_uc6; clean_uc7; clean_uc8; clean_uc9
  if [[ "${HARD}" == "true" ]]; then
    warn "--hard: removing Kueue ClusterQueues, LocalQueues, and hardware profiles"
    oc delete clusterqueue --all --ignore-not-found 2>/dev/null || true
    oc delete resourceflavor --all --ignore-not-found 2>/dev/null || true
    oc delete hardwareprofile -A --all --ignore-not-found 2>/dev/null || true
  fi
  success "Full cleanup complete — environment ready for next demo run"
else
  for target in "${TARGETS[@]}"; do
    case "${target}" in
      uc2) clean_uc2 ;;
      uc3) clean_uc3 ;;
      uc4) clean_uc4 ;;
      uc5) clean_uc5 ;;
      uc6) clean_uc6 ;;
      uc7) clean_uc7 ;;
      uc8) clean_uc8 ;;
      uc9) clean_uc9 ;;
      *) warn "Unknown target: ${target}. Valid: uc2 uc3 uc4 uc5 uc6 uc7 uc8 uc9 all" ;;
    esac
  done
fi
