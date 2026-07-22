# UC8: Gang Scheduling for Multi-GPU Jobs (8 min)

## Story

Distributed training is not parallelism — it is synchronization. When you launch a 4-GPU training job, all four workers must start at the same instant and communicate from the first step. If three workers start and one waits for GPU capacity, the three that started block on a barrier, the fourth never comes, and you have a deadlock — all four GPUs stuck, doing nothing. Kueue prevents this with atomic gang scheduling: all four pods are admitted together, or none of them start.

## What You're Showing

- Without gang scheduling: partial starts lead to deadlock and wasted GPU time
- Kueue holds a 4-pod gang job in `Inadmissible` state when only 1 of 4 GPU slices is free
- Releasing one filler job frees enough capacity — all 4 gang pods start simultaneously
- Kueue's `parallelism` field is the gang size — no special API required

## Setup

Verify research-team-project has access to the research-queue and that at least 4 × 1g.6gb slices are nominally available:

```bash
oc get clusterqueue research-cluster-queue \
  -o jsonpath='{.spec.resourceGroups}' | python3 -m json.tool
```

Expected: `nominalQuota: "4"` for `nvidia.com/mig-1g.6gb`.

Verify no leftover jobs from a previous run:

```bash
oc delete jobs -n research-team-project \
  -l demo/uc=uc8-gang --ignore-not-found
```

## Demo Steps

### Step 1: Explain the Problem — Why Gang Scheduling Matters

What to say: "Distributed training uses collective operations — AllReduce, barrier synchronization. Worker 0 sends a gradient tensor and then calls `barrier()`. It will wait there until ALL other workers have also called `barrier()`. If worker 3 never starts because there is no GPU for it, worker 0 waits forever. Workers 1 and 2 wait forever. You have burned three GPUs doing nothing."

Draw on whiteboard or show slide:

```
Without gang scheduling:
  Worker 0 → starts  → waits at barrier() ─┐
  Worker 1 → starts  → waits at barrier() ─┤  DEADLOCK
  Worker 2 → starts  → waits at barrier() ─┘
  Worker 3 → PENDING → no GPU available

With Kueue gang scheduling:
  All 4 workers → INADMISSIBLE (only 3 GPUs free)
  → one GPU freed →
  All 4 workers → ADMITTED simultaneously → training proceeds
```

### Step 2: Fill 3 of 4 Available 1g.6gb Slices with Filler Jobs

What to say: "I'm going to fill 3 of the 4 available 1g.6gb MIG slices with low-priority filler jobs. That leaves exactly 1 free — not enough for a 4-pod gang."

```bash
oc apply -f 06-kueue/07-gang-scheduling-job.yaml
```

This file applies `filler-job-1`, `filler-job-2`, `filler-job-3` AND the gang job `distributed-training-gang`.

Verify filler jobs are admitted and running:

```bash
oc get workloads -n research-team-project \
  -l demo/uc=uc8-gang
```

Expected — 3 filler workloads Admitted, gang workload Inadmissible:

```
NAME                              QUEUE           RESERVED IN            ADMITTED   REASON
filler-job-1-…                   research-queue  research-cluster-queue  True
filler-job-2-…                   research-queue  research-cluster-queue  True
filler-job-3-…                   research-queue  research-cluster-queue  True
distributed-training-gang-…      research-queue  <none>                 False      Inadmissible
```

### Step 3: Show the Gang Job Is Inadmissible

```bash
oc get workloads -n research-team-project \
  -l demo/role=gang-job -o yaml | grep -A10 "conditions:"
```

Expected condition:

```yaml
conditions:
  - lastTransitionTime: "..."
    message: "insufficient quota for nvidia.com/mig-1g.6gb in flavor a30-mig-1g6gb, 4 more needed"
    reason: Inadmissible
    status: "False"
    type: QuotaReserved
```

```bash
oc get pods -n research-team-project -l demo/role=gang-worker
```

Expected: **no pods at all** — Kueue has not created any pods because the gang cannot be admitted atomically.

What to say: "Zero pods. Not three out of four — zero. Kueue is refusing to start any worker until all four can start together. This is the guarantee: no partial launches."

### Step 4: Show Quota State — Only 1 Slice Free

```bash
oc get clusterqueue research-cluster-queue \
  -o jsonpath='{.status.flavorsUsage}' | python3 -m json.tool
```

Expected — `inUse: 3`, `nominalQuota: 4`, so only 1 free:

```json
[
  {
    "name": "a30-mig-1g6gb",
    "resources": [
      {
        "borrowed": "0",
        "inUse": "3",
        "name": "nvidia.com/mig-1g.6gb"
      }
    ]
  }
]
```

What to say: "Three slices used by filler jobs. One free. The gang needs four — all at once. It waits."

### Step 5: Delete One Filler Job — Watch All 4 Gang Pods Start Simultaneously

What to say: "I'm going to delete one filler job. That releases one slice — now four are free. Watch what Kueue does."

```bash
oc delete job filler-job-1 -n research-team-project
```

Immediately watch pods:

```bash
oc get pods -n research-team-project \
  -l demo/role=gang-worker -w
```

Expected — all 4 pods transition from `Pending` to `Running` at the same timestamp:

```
NAME                                READY   STATUS    AGE
distributed-training-gang-0-…      0/1     Pending   2s
distributed-training-gang-1-…      0/1     Pending   2s
distributed-training-gang-2-…      0/1     Pending   2s
distributed-training-gang-3-…      0/1     Pending   2s
distributed-training-gang-0-…      1/1     Running   4s
distributed-training-gang-1-…      1/1     Running   4s
distributed-training-gang-2-…      1/1     Running   4s
distributed-training-gang-3-…      1/1     Running   4s
```

What to say: "All four pods. Same second. Kueue waited until capacity existed for the entire gang, then admitted them atomically. No deadlock possible."

### Step 6: Read the Gang Job Output

```bash
oc logs -n research-team-project \
  -l demo/role=gang-worker --prefix
```

Expected — all workers report starting simultaneously:

```
[pod/distributed-training-gang-0-…] [Worker 0/4] Gang-scheduled distributed training started!
[pod/distributed-training-gang-0-…] [Worker 0] GPU: NVIDIA A30
[pod/distributed-training-gang-0-…] [Worker 0] All 4 workers started SIMULTANEOUSLY — gang scheduling enforced by Kueue
[pod/distributed-training-gang-1-…] [Worker 1/4] Gang-scheduled distributed training started!
[pod/distributed-training-gang-2-…] [Worker 2/4] Gang-scheduled distributed training started!
[pod/distributed-training-gang-3-…] [Worker 3/4] Gang-scheduled distributed training started!
```

### Step 7: Show the Workload Status — Now Admitted

```bash
oc get workloads -n research-team-project -l demo/uc=uc8-gang
```

Expected:

```
NAME                              QUEUE           RESERVED IN            ADMITTED
distributed-training-gang-…      research-queue  research-cluster-queue  True
```

What to say: "The gang is admitted, running, and synchronized. No partial starts. No wasted GPU time. No deadlock. That is the value of gang scheduling."

## Watch Commands

Run in separate terminals during Steps 3–5:

```bash
# Terminal 1: Watch workloads change from Inadmissible to Admitted
oc get workloads -n research-team-project -w
```

```bash
# Terminal 2: Watch pods — the critical moment is all 4 going Running at once
oc get pods -n research-team-project -l demo/role=gang-worker -w
```

```bash
# Terminal 3: Monitor quota — shows the moment 1 slice frees and 4 are consumed at once
watch -n2 'oc get clusterqueue research-cluster-queue \
  -o jsonpath="{.status.flavorsUsage}" | python3 -m json.tool'
```

## Key Message

> "4 GPUs or nothing. Kueue guarantees atomic start — no partial launches, no wasted GPU time."

## Cleanup

```bash
# Run from repo root:
bash cleanup.sh uc8
```
