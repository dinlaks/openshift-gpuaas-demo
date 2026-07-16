# UC4: Queue-Based Scheduling (8 min)

## Story
In a shared GPU environment, teams submit more work than the cluster can absorb at once. Without a queue, excess jobs fail and engineers retry manually — wasting time and creating operational noise. With Kueue, jobs that exceed current capacity wait in an ordered queue and are admitted automatically the instant a slot opens. The platform absorbs demand spikes without any human intervention.

## What You're Showing
- Three research jobs filling charlie's queue quota — all admitted and running
- A fourth job hitting the quota ceiling and transitioning to `Inadmissible`
- Deleting one running job — the fourth job automatically admitted within seconds
- The full lifecycle visible in real time with `oc get workloads -w`

## Setup
- research-cluster-queue must be empty at the start (no running workloads)
- Confirm quota before starting:

```bash
oc describe clusterqueue research-cluster-queue | grep -A10 "Resource Groups"
```

- Ensure the demo jobs manifest is present:

```bash
ls -la 06-kueue/05-queue-demo-jobs.yaml
```

- Optional: open a split terminal with the watch command pre-loaded so it is visible as soon as jobs are submitted.

---

## Demo Steps

### Step 1: Show the Empty Queue
**Say:** "We're starting fresh. Charlie's research queue is empty — no running jobs, no pending workloads."

```bash
oc get workloads -n research-team-project
oc get clusterqueue research-cluster-queue -o wide
```

Confirm:
- `ADMITTED WORKLOADS: 0`
- `PENDING WORKLOADS: 0`

**Say:** "We're about to fill this queue to capacity, then push it past the limit — and let Kueue handle the rest."

---

### Step 2: Submit Three Jobs to Fill the Quota
**Say:** "The research cluster queue has a nominalQuota of 3 MIG slices — enough for three simultaneous jobs. Let's fill it."

```bash
oc apply -f 06-kueue/05-queue-demo-jobs.yaml -n research-team-project
```

Watch the admission in real time:

```bash
oc get workloads -n research-team-project -w
```

All three workloads should transition through:
`Pending` → `QuotaReserved` → `Admitted`

Once all three are admitted:

```bash
oc get workloads -n research-team-project
oc get clusterqueue research-cluster-queue -o wide
```

**Say:** "Three jobs, three slices, three simultaneous admissions. The queue is now at full capacity."

---

### Step 3: Submit the Fourth Job — Watch It Go Inadmissible
**Say:** "Now let's push past the limit. I'll submit a fourth job while the queue is fully occupied."

```bash
oc apply -f 06-kueue/05-queue-demo-jobs-overflow.yaml -n research-team-project
```

Watch the fourth workload:

```bash
oc get workloads -n research-team-project -w
```

The fourth workload will remain in `Inadmissible` or `Pending` state.

Describe the workload to show the reason:

```bash
# Get the name of the pending/inadmissible workload
PENDING_WL=$(oc get workload -n research-team-project -o json | \
  jq -r '.items[] | select(.status.conditions[]?.reason == "Inadmissible" or .status.conditions[]?.type == "QuotaReserved" and .status.conditions[]?.status == "False") | .metadata.name' | head -1)

oc describe workload $PENDING_WL -n research-team-project
```

Point to the `Conditions` section:
- `Type: Admitted`, `Status: False`
- `Reason: Inadmissible`
- `Message:` referencing insufficient quota in `research-cluster-queue`

**Say:** "The job didn't fail. It didn't error. It is waiting — intelligently, with full observability. The operator can see exactly why it's queued and what it's waiting for."

---

### Step 4: Delete a Running Job — Watch the Fourth Admit Automatically
**Say:** "Now watch what happens the moment I free up a slot."

Identify a running workload and delete its backing job:

```bash
# List running jobs
oc get jobs -n research-team-project

# Delete the first running job
oc delete job -n research-team-project $(oc get jobs -n research-team-project -o name | head -1)
```

Immediately switch attention to the workload watch:

```bash
oc get workloads -n research-team-project -w
```

Within a few seconds, the fourth workload transitions:
`Inadmissible` → `QuotaReserved` → `Admitted`

**Say:** "No cron job. No retry script. No engineer watching a dashboard and clicking buttons. Kueue saw the free slot and admitted the waiting job automatically. This is the queue contract: your job will run, in order, as soon as capacity is available."

---

### Step 5: Show Final State
```bash
oc get workloads -n research-team-project
oc get clusterqueue research-cluster-queue -o wide
```

Three workloads running again, zero pending. The queue has self-healed.

**Say:** "Platform teams don't babysit queues. Users don't retry failed jobs. The system manages itself."

---

## Watch Commands
Run in a dedicated terminal before submitting any jobs:

```bash
# Real-time workload status in charlie's project
oc get workloads -n research-team-project -w

# In a second pane: live queue utilization
watch -n 2 "oc get clusterqueue research-cluster-queue -o wide"
```

## Key Message
> "Jobs wait intelligently. No failures, no manual intervention. Kueue manages the queue."

## Cleanup
```bash
bash cleanup.sh uc4
```
