#!/usr/bin/env bash
# UC10 — GPU Booking Plugin Demo
#
# Three flows demonstrating end-to-end GPU booking:
#   1   — Happy path: alice books MIG slice, submits inference job, sees it run
#   2   — Expiry: simulate booking window closing, watch job evict gracefully
#   3a  — Booking management step 1: charlie books and submits job (fills a slot)
#   3b  — Booking management step 2: bob submits (pending) → cancel charlie → bob auto-admits
#   cleanup — Remove all UC10 demo workloads
#
# Prerequisites:
#   - deploy.sh has been run (plugin installed, user namespaces created)
#   - Bookings made in the GPU Booking portal (OCP Console → GPU Bookings)
#     before running steps 1 and 3b
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${REPO_ROOT}/lib/common.sh"
load_env
resolve_gpu_config
require_oc_login

case "${1:-}" in

  # ── Flow 1: Happy path — alice's inference job on reserved slot ───────────
  1)
    header "UC10 Flow 1: Alice inference job on reserved MIG slice"
    info "Prerequisites: Alice must have an active booking in the GPU portal"
    info "  → OCP Console → GPU Bookings → book MIG 1g.6gb for today"
    echo ""
    apply_template "${SCRIPT_DIR}/flow1-inference-job.yaml"
    success "alice-reserved-inference submitted to LocalQueue/reserved in user-alice"
    echo ""
    info "Watch in RHOAI Dashboard → user-alice project → Workload metrics"
    info "Or CLI: oc get workloads -n user-alice -w"
    info "Pod logs: oc logs -n user-alice -l demo/flow=flow1 -f"
    ;;

  # ── Flow 2: Simulate expiry — booking window closes, job evicts ───────────
  2)
    header "UC10 Flow 2: Simulate booking expiry — HoldAndDrain eviction"
    # Find alice's active booking ClusterQueue
    BOOKING_CQ=$(oc get clusterqueue -l "rhai-tmm.dev/until" --no-headers       -o custom-columns=':metadata.name' 2>/dev/null | grep "user-alice" | head -1 || true)

    if [[ -z "${BOOKING_CQ}" ]]; then
      error "No active booking ClusterQueue found for alice."
      error "Make a booking in the portal first, run flow 1, then retry flow 2."
      exit 1
    fi

    info "Found booking ClusterQueue: ${BOOKING_CQ}"
    info "Setting stopPolicy: HoldAndDrain — this actively evicts running workloads..."
    oc patch clusterqueue "${BOOKING_CQ}" --type=merge       -p '{"spec":{"stopPolicy":"HoldAndDrain"}}'
    success "HoldAndDrain set on ${BOOKING_CQ}"
    echo ""
    info "Kueue will now:"
    info "  1. Mark alice\'s workload for eviction"
    info "  2. Delete the running pod gracefully (SIGTERM)"
    info "  3. Workload status: Admitted → Inadmissible"
    echo ""
    info "Watch RHOAI Dashboard → user-alice → Workload metrics"
    info "Or CLI: oc get workloads -n user-alice -w"
    info "        oc get pods -n user-alice -w"
    echo ""
    echo ""
    warn "The booking record still exists in the plugin portal database."
    warn "To fully release the slot, cancel the booking in the GPU Bookings portal:"
    info "  1. Open OCP Console → GPU Bookings"
    info "  2. Find alice\'s booking → click Cancel"
    info "  3. Plugin cleans up ClusterQueue, LocalQueue, and HardwareProfile"
    ;;

  # ── Flow 3-fill: Filler jobs to occupy remaining MIG slots ──────────────────
  3-fill)
    header "UC10 Flow 3 setup: Fill remaining MIG slots"
    apply_template "${SCRIPT_DIR}/flow3-filler-jobs.yaml"
    success "Filler jobs submitted to research-queue in research-team-project"
    echo ""
    info "These occupy 3 MIG 1g.6gb slots — with charlie's job, all 4 are full"
    info "Wait for pods to be Running: oc get pods -n research-team-project -l demo/flow=flow3-filler -w"
    ;;

  # ── Flow 3a: Charlie submits medium-priority job on his booking ─────────────
  3a)
    header "UC10 Flow 3a: Charlie submits medium-priority job on his booking"
    info "Prerequisites: Charlie must have an active booking in the GPU portal"
    info "  → OCP Console → GPU Bookings → book MIG 1g.6gb for today"
    echo ""
    apply_template "${SCRIPT_DIR}/flow3-charlie-borrow-job.yaml"
    success "charlie-reserved-medium submitted to LocalQueue/reserved in user-charlie"
    echo ""
    info "Charlie is running on his reserved slot"
    info "Watch: oc get workloads -n user-charlie -w"
    echo ""
    info "Next: run filler jobs to fill remaining slots: bash run-demo.sh 3-fill"
    ;;

  # ── Flow 3b: Bob's booking preempts charlie's borrowed job ───────────────
  3b)
    header "UC10 Flow 3b: Bob's reserved job preempts charlie's borrowed job"
    info "Prerequisites: Bob must have an active booking in the GPU portal"
    info "  → OCP Console → GPU Bookings → book MIG 1g.6gb for today"
    echo ""
    apply_template "${SCRIPT_DIR}/flow3-bob-inference-job.yaml"
    success "bob-reserved-inference submitted to LocalQueue/reserved in user-bob"
    echo ""
    info "Bob's booking ClusterQueue has reclaimWithinCohort: Any"
    info "Charlie's borrowed job will be preempted to enforce Bob's reservation"
    info ""
    info "Watch RHOAI Dashboard → Workload metrics:"
    info "  user-charlie: charlie goes Inadmissible"
    info "  user-bob: bob goes Admitted"
    info ""
    info "Or CLI: oc get workloads -A -l demo/uc=uc10-booking -w"
    ;;

  # ── Cleanup ───────────────────────────────────────────────────────────────
  cleanup)
    header "UC10 Cleanup"
    for ns in user-alice user-bob user-charlie research-team-project; do
      oc delete job -n "${ns}" -l "demo/uc=uc10-booking" --ignore-not-found 2>/dev/null || true
      oc delete pod -n "${ns}" -l "demo/uc=uc10-booking" \
        --force --grace-period=0 --ignore-not-found 2>/dev/null || true
    done
    success "All UC10 demo workloads removed (including filler jobs)"

    # Wipe booking records from GPU Booking portal database
    info "Clearing booking portal database..."
    TOKEN=$(oc whoami -t 2>/dev/null || true)
    if [[ -n "${TOKEN}" ]]; then
      oc port-forward -n gpu-booking-app-plugin svc/gpu-booking-plugin 9443:9443 &>/dev/null &
      PF_PID=$!
      sleep 2
      RESULT=$(curl -sk -X DELETE "https://localhost:9443/api/admin" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '{"error":"failed"}')
      kill ${PF_PID} 2>/dev/null || true
      wait ${PF_PID} 2>/dev/null || true
      if echo "${RESULT}" | grep -q '"deleted"'; then
        success "Booking portal database cleared"
      else
        warn "Could not clear portal database: ${RESULT}"
      fi
    else
      warn "No OCP token available — clear bookings manually in the GPU Bookings portal"
    fi
    ;;

  *)
    echo ""
    echo "UC10 — GPU Booking Plugin Demo"
    echo ""
    echo "Usage: bash run-demo.sh <flow>"
    echo ""
    echo "  1       Flow 1: Alice books MIG slice → submits inference job → runs on reservation"
    echo "  2       Flow 2: Cancel booking in portal → pod evicts → resources cleaned up"
    echo "  3-fill  Flow 3 setup: Fill remaining MIG slots with filler jobs"
    echo "  3a      Flow 3 step 1: Charlie books and submits job on reserved slot"
    echo "  3b      Flow 3 step 2: Bob books and submits (pending) — cancel charlie → bob admits"
    echo "  cleanup Remove all UC10 demo workloads (including fillers)"
    echo ""
    echo "Flow order for demo:"
    echo "  1. Log in as alice → book MIG 1g.6gb in GPU portal"
    echo "  2. bash run-demo.sh 1"
    echo "  3. Cancel alice booking in portal (Flow 2)"
    echo "  4. bash run-demo.sh cleanup"
    echo "  5. Log in as charlie → book → bash run-demo.sh 3a"
    echo "  6. bash run-demo.sh 3-fill  (fill remaining MIG slots)"
    echo "  7. Log in as bob → book → bash run-demo.sh 3b (bob pending)"
    echo "  8. Log in as charlie → cancel booking → bob auto-admits"
    echo ""
    ;;
esac
