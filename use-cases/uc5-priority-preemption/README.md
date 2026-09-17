# UC5: Workload Priority (8 min)

> **Demo Recording:** [▶ Watch on YouTube](https://youtu.be/3sD9Edd9qQQ) — narrated live demo on a real cluster, no login required.


## Story
Not all GPU workloads are equal. A batch fine-tuning job that runs overnight should yield to a production inference request that needs to start in seconds. Without priority enforcement, the first job to claim a GPU holds it regardless of business value — turning your expensive accelerator estate into first-come-first-served infrastructure. Kueue preemption policy makes priority a platform contract: high-priority workloads always run, even if that means evicting lower-priority ones.

## What You're Showing
- Alice's medium-priority dev experiment occupying her only `mig-1g.6gb` slot in `inference-cluster-queue`
- Alice's high-priority production inference job arriving — triggering within-queue preemption
- Kueue evicting Alice's own dev job to admit the production job immediately (no borrowing available — `borrowingLimit: "0"`)
- The preempted dev job automatically re-queuing and re-admitting when the production job finishes

## Setup
- `inference-cluster-queue` must be in `Active` state
- PriorityClasses must be applied: `high-priority` (value: 1000), `medium-priority` (value: 500)
- Confirm before starting:

```bash
oc get priorityclass | grep -E "high-priority|medium-priority"
oc get clusterqueue inference-cluster-queue -o wide
```

---

## Demo Steps

> **Dashboard setup (open before starting):** Keep two RHOAI Dashboard tabs open and toggle between them throughout the demo:
> - **Tab 1 — Observe & Monitor > Infrastructure**: GPU utilization, queue allocation donuts — watch the slot stay occupied through preemption
> - **Tab 2 — Observe & Monitor > Workload metrics**: admission state and priority per workload — filter by `inference-team-project`

### Step 1: Show the Priority Classes
**Say:** "Before we see preemption, let's establish the priority hierarchy. These are Kubernetes PriorityClasses — platform policy, not a setting buried in a YAML that developers control."

```bash
oc get priorityclass -o custom-columns=\
'NAME:.metadata.name,\
VALUE:.value,\
GLOBAL-DEFAULT:.globalDefault,\
DESCRIPTION:.description'
```

Point out:
- `high-priority` with value `1000` — for production inference workloads
- `medium-priority` with value `500` — for DS experimentation and training
- `low-priority` with value `100` — for background/batch jobs (if present)

**Say:** "These values are what Kueue uses to decide who gets evicted when there is contention. Higher number wins."

---

### Step 2: Submit Alice's Medium-Priority Dev Job
**Say:** "Alice is running a development experiment — medium priority. Her inference queue has exactly one `mig-1g.6gb` slot and it's now occupied. And with `borrowingLimit: 0`, she cannot borrow from other teams."

```bash
bash use-cases/uc5-priority-preemption/run-demo.sh 1
```

Wait for the workload to be admitted:

```bash
oc get workloads -n inference-team-project -w
```

Once `Admitted`, confirm queue utilization:

```bash
oc get clusterqueue inference-cluster-queue -o wide
```

**Say:** "Alice's dev job is running. Her queue is at capacity — borrowing is disabled for the inference queue, so her production job has nowhere to go... unless Kueue acts."

Switch to the GPUaaS Infrastructure dashboard:

Switch to **Tab 1 (Infrastructure)**

**Say:** "Scroll to `gpuaas-cohort` → `inference-cluster-queue`. Total accelerators shows 1 active workload. Compute and memory gauges are non-zero. Queue is at capacity — no headroom. Now watch what happens when a higher-priority job arrives."

Switch back to CLI.

---

### Step 3: Submit Alice's High-Priority Production Inference Job

**Before submitting** — ensure the audience is watching the workload list in **Tab 2 (Workload metrics)** or a live watch terminal. Preemption happens within seconds of submission.

Open a dedicated terminal with the watch running:
```bash
oc get workloads -n inference-team-project -w
```

Or switch to **Tab 2 (Workload metrics)** → filter by `inference-team-project` to see admission state and priority update live.

**Say:** "Watch the screen — I'm about to submit Alice's production inference job. It's high priority. Her dev slot is occupied. Kueue has exactly one choice. And after about 90 seconds, watch what happens when it finishes."

```bash
bash use-cases/uc5-priority-preemption/run-demo.sh 2
```

Immediately watch workloads:

```bash
oc get workloads -n inference-team-project -w
```

Within seconds, observe:
- `alice-inference-job`: `Pending` → `Admitted`
- `alice-dev-medium`: `Admitted` → `Evicted` (preempted by higher-priority job in same queue)

**Say:** "Kueue preempted Alice's own dev job to make room for her production job. This is `withinClusterQueue: LowerPriority` — the platform enforces priority as policy. No human intervened."

Open the GPUaaS Infrastructure dashboard:

Switch to **Tab 1 (Infrastructure)**

**Say:** "Notice the `inference-cluster-queue` card — total accelerators still shows 1 in use. The compute and memory gauges stayed non-zero throughout. The slot never went idle — the platform handed it directly from the dev job to the production job."

---

### Step 4: Inspect the Preempted Workload
**Say:** "Let's see what happened to Alice's dev job. Critically — it didn't disappear. It went back to the queue."

```bash
oc get workload -n inference-team-project
oc describe workload alice-dev-medium -n inference-team-project
```

Point out in the output:
- `Conditions` section showing `Reason: Preempted`
- `Message` identifying the higher-priority workload that triggered preemption
- The workload is in `Inadmissible` state, not deleted — it will be re-admitted when capacity opens

```bash
oc get pods -n inference-team-project
```

**Say:** "Alice's dev job was interrupted — but it's not gone. As soon as her inference job finishes and frees a slot, Kueue will re-admit it automatically. No manual resubmission needed."

---

### Step 5: Watch Re-admission After alice's Job Completes

> **Timing note:** The inference job runs for ~90 seconds. Start this step immediately after Step 4 so the audience is watching when re-admission fires. Keep the workload watch running in a visible terminal — the transition happens automatically within seconds of the inference job completing.

**Say:** "Alice's inference job is short — a validation pass, about 90 seconds. Watch this terminal — the moment it finishes, the platform acts."

Monitor in real time:

```bash
oc get workloads -A -w
```

When `alice-inference-job` completes and transitions to `Finished`:
- The freed slot is immediately reclaimed
- `alice-dev-medium` transitions from `Inadmissible` → `Admitted`
- Alice's dev pod restarts and resumes

```bash
oc get workloads -n inference-team-project
```

**Say:** "Production got what it needed, instantly. And the moment it was done, the platform restored Alice's dev work. No tickets, no manual re-submissions, no lost jobs."

Switch to the GPUaaS Infrastructure dashboard:

Switch to **Tab 1 (Infrastructure)**

**Say:** "Look at the `inference-cluster-queue` card throughout this entire sequence — 1 accelerator in use the whole time. Compute consumption stayed non-zero. The slot went dev → production → dev without ever dropping to idle. The borrowing trends chart shows a flat, uninterrupted line. That's the efficiency guarantee of priority-aware scheduling."

Switch back to CLI.

---

### Step 6: Show the Full Priority Audit Trail
**Say:** "Platform teams can audit every preemption decision. This is essential for chargebacks and SLA reporting."

```bash
# Show preemption events
oc get events -n inference-team-project --field-selector=reason=Preempted --sort-by='.lastTimestamp'

# Show events from Kueue controller
oc get events -n openshift-kueue-operator --sort-by='.lastTimestamp' | tail -20
```

## Watch Commands
Run in a dedicated terminal before submitting any jobs — keep it visible on the projector:

```bash
# Live workload status across all projects
watch -n 2 "oc get workloads -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PRIORITY:.spec.priorityClassName,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason'"

# In a second pane: live pod status in inference namespace
watch -n 2 "oc get pods -n inference-team-project -o wide"
```

## Key Message
> "Production never waits behind dev. Priority is policy, not luck."

## Cleanup
```bash
# Run from repo root:
bash cleanup.sh uc5
```
