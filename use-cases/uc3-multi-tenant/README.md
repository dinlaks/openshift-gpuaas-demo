# UC3: Multiple Tenants with Quotas (8 min)

## Story
Five teams share a single GPU pool. Without enforcement, the fastest-moving team wins and everyone else files tickets. With Kueue, each team gets a guaranteed quota expressed as Kubernetes-native policy — and when a team isn't using its full allocation, idle capacity flows to whoever needs it through cohort borrowing. The GPU pool becomes a shared resource that feels dedicated to every team simultaneously.

## What You're Showing
- Five ClusterQueues with distinct `nominalQuota` values mapped to real GPU slice types
- Cohort borrowing in action: charlie's research job absorbs idle inference-team quota automatically
- Quota enforcement in action: a fifth research job queues rather than failing when charlie's allocation is exhausted
- The full picture as a platform operator via CLI

## Setup
- All five Kueue ClusterQueues must be present and in `Active` state
- At least one ClusterQueue should have headroom (inference or finetune is ideal — start with no running jobs there)
- charlie's research queue should be at or near its `nominalQuota` before the borrowing demo

```bash
# Verify all queues are healthy
oc get clusterqueue -o wide

# Confirm cohort membership
oc get clusterqueue -o json | jq '.items[] | {name: .metadata.name, cohort: .spec.cohort, quota: .spec.resourceGroups}'
```

---

## Demo Steps

### Step 1: Show the Full Queue Landscape
**Say:** "Here is the entire GPU estate, expressed as policy. Five teams, one cluster, five queues — each with a guaranteed slice of capacity."

```bash
oc get clusterqueue -o wide
```

Walk the audience through the output columns:
- `COHORT` — all queues belong to the same cohort, enabling borrowing
- `PENDING WORKLOADS` — jobs waiting for admission
- `ADMITTED WORKLOADS` — jobs currently running
- `NOMINAL QUOTA` — the guaranteed entitlement per queue

**Say:** "Each row is a team contract. The quota isn't a suggestion — it's enforced by the scheduler."

---

### Step 2: Drill Into a Single Queue
**Say:** "Let's look at the inference queue in detail. Alice's team has the highest quota because inference workloads are latency-sensitive and revenue-generating."

```bash
oc describe clusterqueue inference-cluster-queue
```

Highlight:
- `resourceGroups` section showing `nvidia.com/mig-1g.6gb` and `nvidia.com/mig-2g.12gb` with specific nominal values
- `cohort: gpu-sharing-cohort` — the key that enables borrowing
- `preemption` policy if configured

Then show the research queue for contrast:

```bash
oc describe clusterqueue research-cluster-queue
```

Point out the lower nominalQuota for `mig-1g.6gb` only — charlie's team is economy tier.

---

### Step 3: Show Cohort Borrowing (charlie borrows from inference)
**Say:** "Right now, alice's inference team has spare capacity. Watch what happens when charlie submits more jobs than his quota allows."

First, confirm inference queue is idle:

```bash
oc get clusterqueue inference-cluster-queue -o jsonpath='{.status.admittedWorkloads}'
```

Submit extra research jobs that exceed charlie's nominalQuota:

```bash
oc apply -f 06-kueue/03-multi-tenant-jobs.yaml -n research-team-project
```

Watch the workloads:

```bash
oc get workloads -n research-team-project -w
```

**Say:** "Charlie submitted more than his guaranteed quota. Normally you'd expect a failure or a hard block. Instead, watch — the job borrows from the inference pool's unused capacity and runs."

Point out the `status.admission` field on the workload showing it was admitted above nominalQuota via borrowing:

```bash
oc describe workload -n research-team-project $(oc get workload -n research-team-project -o name | tail -1)
```

Look for `BorrowingLimit` and the cohort reference in the workload status.

---

### Step 4: Show Quota Enforcement (job queues, doesn't fail)
**Say:** "Now let's exhaust charlie's quota and borrow limit, then submit one more job. This is the critical behavior — we don't want a hard failure, we want intelligent queuing."

Confirm charlie's workloads are using full allocation:

```bash
oc get workloads -n research-team-project
```

Submit the excess job:

```bash
oc apply -f 06-kueue/04-overflow-research-job.yaml -n research-team-project
```

```bash
oc get workloads -n research-team-project -w
```

**Say:** "The fifth job goes `Inadmissible` — Kueue knows there is no capacity for it right now. But notice: the job exists, it's tracked, it's waiting. The moment capacity frees up, Kueue will admit it automatically. No retries, no failures, no operations page."

Show the workload status detail:

```bash
oc describe workload -n research-team-project $(oc get workload -n research-team-project --field-selector=status.conditions[0].type=Inadmissible -o name 2>/dev/null | head -1)
```

---

### Step 5: Show the Full Multi-Tenant Picture (operator summary)
**Say:** "Here is the view a platform team would monitor. Every team's usage, in one command."

```bash
# All queues and their current utilization
oc get clusterqueue -o custom-columns=\
'QUEUE:.metadata.name,\
COHORT:.spec.cohort,\
ADMITTED:.status.admittedWorkloads,\
PENDING:.status.pendingWorkloads,\
RESERVING:.status.reservingWorkloads'

# All workloads across all team namespaces
oc get workloads -A
```

## Watch Commands
Run in a separate terminal throughout the demo:

```bash
# Live queue status across all ClusterQueues
watch -n 3 "oc get clusterqueue -o wide"

# Live workload admission status across all projects
watch -n 3 "oc get workloads -A"
```

## Key Message
> "5 teams, one GPU pool, zero conflicts. Kueue enforces the boundaries."

## Cleanup
```bash
# Run from repo root:
bash cleanup.sh uc3
```
