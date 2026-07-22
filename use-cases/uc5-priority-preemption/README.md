# UC5: Workload Priority (8 min)

## Story
Not all GPU workloads are equal. A batch fine-tuning job that runs overnight should yield to a production inference request that needs to start in seconds. Without priority enforcement, the first job to claim a GPU holds it regardless of business value — turning your expensive accelerator estate into first-come-first-served infrastructure. Kueue preemption policy makes priority a platform contract: high-priority workloads always run, even if that means evicting lower-priority ones.

## What You're Showing
- DS queue saturated with medium-priority batch jobs (bob's workloads)
- A high-priority inference job submitted by alice
- Kueue preempting a medium-priority DS job to make room for alice's workload — with full observability
- The preempted job automatically re-queuing and resuming when capacity is available

## Setup
- ds-cluster-queue and inference-cluster-queue must both be in `Active` state
- PriorityClasses must be applied: `high-priority` (value: 1000), `medium-priority` (value: 500)
- Confirm before starting:

```bash
oc get priorityclass | grep -E "high-priority|medium-priority"
oc get clusterqueue ds-cluster-queue inference-cluster-queue -o wide
```

- Ensure the priority demo manifests are present:

```bash
ls -la 06-kueue/06-priority-demo-jobs.yaml
```

---

## Demo Steps

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

### Step 2: Fill the DS Queue with Medium-Priority Jobs
**Say:** "Bob's data science team is running experiments. He's submitted several medium-priority jobs and they've been admitted — the queue is full."

```bash
# Submit medium-priority DS jobs to fill the ds-cluster-queue
oc apply -f 06-kueue/06-priority-demo-jobs.yaml -n ds-team-project
```

Wait for all DS workloads to be admitted:

```bash
oc get workloads -n ds-team-project -w
```

Once all are in `Admitted` state, confirm queue utilization:

```bash
oc get clusterqueue ds-cluster-queue -o wide
```

**Say:** "Bob's queue is at capacity. Every GPU slice the DS team is entitled to is in use. Under normal circumstances, any new job would have to wait."

---

### Step 3: Submit a High-Priority Inference Job
**Say:** "Alice now needs to run an urgent inference validation job — high priority, production classification. Watch what Kueue does."

```bash
oc apply -f 06-kueue/06-priority-inference-job.yaml -n inference-team-project
```

Immediately watch workloads across both namespaces:

```bash
oc get workloads -A -w
```

Within seconds, observe:
- alice's inference workload: `Pending` → `Admitted`
- One of bob's DS workloads: `Admitted` → `Evicted` (or `Preempted`)

**Say:** "Kueue made a decision in real time. It identified the lowest-priority medium-priority job in the cohort, evicted it, and admitted alice's high-priority job in its place. No human decided this. The platform did."

---

### Step 4: Inspect the Preempted Workload
**Say:** "Let's see what happened to the evicted job. Critically — it didn't disappear. It went back to the queue."

```bash
# Find the preempted workload
PREEMPTED=$(oc get workload -n ds-team-project -o json | \
  jq -r '.items[] | select(.status.conditions[]?.reason == "Preempted" or .metadata.annotations["kueue.x-k8s.io/preempted"] != null) | .metadata.name' | head -1)

oc describe workload $PREEMPTED -n ds-team-project
```

Point out in the output:
- `Conditions` section showing `Reason: Preempted`
- `Message` identifying the higher-priority workload that triggered preemption
- The workload is in `Inadmissible` state, not deleted — it will be re-admitted when capacity opens

```bash
# Show the preempted job's pod was terminated
oc get pods -n ds-team-project
```

**Say:** "Bob's job was interrupted — but it's not gone. As soon as alice's inference job finishes and frees a slot, Kueue will re-admit it automatically. Bob doesn't need to do anything."

---

### Step 5: Watch Re-admission After alice's Job Completes
**Say:** "Alice's inference job is short — a validation pass. Let's watch what happens when it finishes."

Monitor in real time:

```bash
oc get workloads -A -w
```

When alice's workload completes and transitions to `Finished`:
- The freed slot is immediately reclaimed
- Bob's preempted workload transitions from `Inadmissible` → `Admitted`
- Bob's pod restarts and resumes

```bash
# Confirm both final states
oc get workloads -n inference-team-project
oc get workloads -n ds-team-project
```

**Say:** "Production got what it needed, instantly. And the moment it was done, the platform restored Bob's work. No tickets, no manual re-submissions, no lost jobs."

---

### Step 6: Show the Full Priority Audit Trail
**Say:** "Platform teams can audit every preemption decision. This is essential for chargebacks and SLA reporting."

```bash
# Show preemption events
oc get events -n ds-team-project --field-selector=reason=Preempted --sort-by='.lastTimestamp'

# Show events from Kueue controller
oc get events -n kueue-system --sort-by='.lastTimestamp' | tail -20
```

## Watch Commands
Run in a dedicated terminal before submitting any jobs — keep it visible on the projector:

```bash
# Live workload status across all projects
watch -n 2 "oc get workloads -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PRIORITY:.spec.priorityClassName,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason'"

# In a second pane: live pod status in both team namespaces
watch -n 2 "oc get pods -n ds-team-project -o wide; echo '---'; oc get pods -n inference-team-project -o wide"
```

## Key Message
> "Production never waits behind dev. Priority is policy, not luck."

## Cleanup
```bash
# Run from repo root:
bash cleanup.sh uc5
```
