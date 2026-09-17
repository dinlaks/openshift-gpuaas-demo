# GPU-as-a-Service — Use Case Overview

Nine use cases that together demonstrate a complete GPU governance platform on OpenShift AI.
Each use case is self-contained and can be run independently after the platform is set up.

---

## UC1 — GPU Flavors & Hardware Profiles (7 min)
**"The right GPU for the right workload — enforced by the platform, not by tickets."**

Five teams share one GPU pool, but not equally. The platform defines GPU tiers (economy MIG slice, premium MIG slice, full GPU) and assigns them per project. Users self-serve from a dropdown — they see only what they're entitled to. Platform policy prevents accidental consumption of scarce resources.

**Audience takeaway:** GPU access is governed. Users can't exceed their tier. No ticket required, no over-provisioning possible.

---

## UC2 — Dynamic Resource Allocation / DRA (10 min)
**"Workloads describe capability, not resource names. The platform finds the right GPU."**

Traditional GPU requests hardcode a resource name (`nvidia.com/gpu`) into the pod spec. DRA replaces this with a capability description — the pod says what it needs, Kubernetes finds the best match dynamically. The GPU reservation is created at schedule time and released the instant the workload finishes — no idle capacity held overnight.

**Audience takeaway:** DRA makes workloads portable across GPU types and eliminates wasted reservations.

---

## UC3 — Multi-Tenant Quotas + Cohort Borrowing (8 min)
**"Five teams, one GPU pool, zero conflicts — enforced by policy, not by honour system."**

Each team gets a guaranteed quota. When a team isn't using its full allocation, idle capacity flows into a shared cohort pool — other teams can borrow it automatically. When all capacity is exhausted, a job waits intelligently rather than failing. No engineer has to monitor and manually redistribute GPUs.

**Audience takeaway:** Teams get fair guaranteed access. Idle GPUs don't sit wasted. Overflow jobs queue, not fail.

---

## UC4 — Queue-Based Scheduling (8 min)
**"Jobs wait intelligently. No failures, no manual intervention. The queue self-heals."**

When GPU demand exceeds current capacity, jobs don't fail — they wait in Kueue's ordered queue. The moment a running job finishes and a slot opens, the next job in line is admitted automatically within seconds. No cron job, no retry script, no engineer watching a dashboard.

**Audience takeaway:** The platform absorbs demand spikes. Every job eventually runs — in order, without human intervention.

---

## UC5 — Workload Priority & Preemption (8 min)
**"Production never waits behind dev. Priority is policy, not luck."**

A dev experiment runs in the inference queue at medium priority. A production inference job arrives at high priority — but the queue is full and borrowing is disabled. Kueue evicts the dev job to make room for production immediately. The dev job is not deleted — it re-queues and re-admits automatically when production finishes. The GPU slot never goes idle.

**Audience takeaway:** High-priority workloads always win. Dev jobs don't block production. Lost work is automatically recovered.

---

## UC6 — Model-Specific Placement (7 min)
**"Large models get large GPUs. Small models get small slices. Automatic — no node selector in the pod spec."**

A large model needs the full 24GB GPU. A small dev model needs only a 6GB MIG slice. Hardware profiles in RHOAI encode this policy — users pick a tier from a dropdown, and Kueue's ResourceFlavors route each workload to the correct physical GPU automatically. No `nodeSelector` in the user's YAML.

**Audience takeaway:** Model placement is policy, not configuration. The right workload lands on the right GPU every time.

---

## UC7 — Global GPU Pool Across Clusters (10 min)
**"Submit once. The platform picks the cluster."**

Two OpenShift clusters are governed by ACM as a single fleet with identical GPU policy. When Cluster A's premium GPU slice fills up, Kueue's MultiKueue automatically dispatches the next job to the spoke cluster — without the user specifying a cluster, resubmitting, or knowing the fleet topology. One queue, two clusters, automatic placement.

**Audience takeaway:** GPU capacity scales across clusters transparently. Users never think about which cluster.

---

## UC8 — Gang Scheduling for Distributed Training (8 min)
**"4 GPUs or nothing. No partial starts, no deadlock, no wasted GPU time."**

Distributed training requires all workers to start simultaneously — if one pod waits for a GPU while others run, everyone blocks at the barrier call and all GPUs sit idle. Kueue holds a 4-pod gang job in `Inadmissible` state until all 4 GPU slots are free at the same instant. All 4 pods start in the same second. Atomicity is enforced by the scheduler, not the application.

**Audience takeaway:** Distributed training is safe. No deadlock possible. No GPU burned waiting for a stragglers.

---

## UC9 — Time-Based GPU Policy (8 min)
**"Friday 6pm: switch to economy GPU tier. Monday 6am: switch back. Automatic."**

Production inference runs on a premium GPU slice weekdays. On weekends, that slice sits mostly idle. A CronJob fires Friday at 6pm: Kueue drains the inference workload, sets the premium quota to zero, and re-admits it on the cheaper economy slice. Monday morning the quota restores and the job moves back. No tickets, no forgotten weekend GPU bills, no manual steps.

**Audience takeaway:** GPU cost optimization is automated. Time-based policies run themselves. Finance sees the savings without engineers lifting a finger.

---

## Quick Reference

| UC | Title | Duration | Key Metric |
|---|---|---|---|
| UC1 | GPU Flavors & Hardware Profiles | 7 min | Per-project hardware profile dropdown |
| UC2 | Dynamic Resource Allocation | 10 min | ResourceClaim lifecycle |
| UC3 | Multi-Tenant Quotas + Cohort Borrowing | 8 min | 5 teams, 1 pool, 0 conflicts |
| UC4 | Queue-Based Scheduling | 8 min | Job waits → auto-admits on slot free |
| UC5 | Workload Priority & Preemption | 8 min | Dev evicted in <5s, auto re-queued |
| UC6 | Model-Specific Placement | 7 min | Full GPU vs MIG slice, same cluster |
| UC7 | Global GPU Pool | 10 min | Cross-cluster dispatch, 1 submission |
| UC8 | Gang Scheduling | 8 min | 4 pods start at same second |
| UC9 | Time-Based Policy | 8 min | Friday→economy, Monday→premium, automatic |
