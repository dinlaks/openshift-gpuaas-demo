# UC9: Time-Based GPU Placement (8 min)

## Story

The inference team runs production workloads Monday through Friday on a premium 2g.12gb GPU slice — 12GB of dedicated memory, full performance. On weekends, that premium slice sits mostly idle. A CronJob fires every Friday at 6pm: Kueue drains the inference workload, sets the 2g.12gb quota to zero, and re-admits the job on a cheaper 1g.6gb slice. Monday at 6am, the quota restores and the job moves back to premium. No manual intervention. No tickets. No forgotten weekend GPU bills.

## What You're Showing

- Inference job running on premium 2g.12gb MIG slice during "weekday" policy
- Weekend CronJob triggers Kueue's `HoldAndDrain` — active job is evicted gracefully
- Quota for 2g.12gb drops to 0 — the premium tier is closed
- Kueue re-admits the inference job automatically on the cheaper 1g.6gb slice
- Weekday CronJob restores premium quota — job moves back, no action required

## Setup

Apply the UC9 manifests (CronJobs, RBAC, inference job):

```bash
oc apply -f 06-kueue/08-time-based-policy.yaml
```

Verify CronJobs exist:

```bash
oc get cronjob -n gpuaas-system
```

Expected:

```
NAME                     SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE
gpuaas-weekend-policy    0 18 * * 5   False     0        <none>
gpuaas-weekday-policy    0 6 * * 1    False     0        <none>
```

Verify the inference-cluster-queue has 2g.12gb quota:

```bash
oc get clusterqueue inference-cluster-queue \
  -o jsonpath='{.spec.resourceGroups}' | python3 -m json.tool
```

Expected: `nominalQuota: "1"` for `nvidia.com/mig-2g.12gb`.

## Demo Steps

### Step 1: Start the Weekday Inference Job (Baseline State)

What to say: "This is Friday afternoon. Alice's inference team is running their production model on the premium 2g.12gb slice — 12GB of dedicated GPU memory, full performance."

```bash
oc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: uc9-inference-weekday
  namespace: inference-team-project
  labels:
    demo/uc: uc9-time-based
    demo/slot: weekday
  annotations:
    kueue.x-k8s.io/queue-name: inference-queue
    kueue.x-k8s.io/priority-class: high-priority
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        demo/uc: uc9-time-based
    spec:
      restartPolicy: Never
      containers:
        - name: inference
          image: pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime
          command: [python, -c]
          args:
            - |
              import torch, time, os
              mem = torch.cuda.get_device_properties(0).total_memory / 1e9
              print(f"WEEKDAY INFERENCE | GPU: {torch.cuda.get_device_name(0)} | VRAM: {mem:.1f}GB")
              print("Running on PREMIUM 2g.12gb slice (12GB) — weekday policy active")
              x = torch.randn(4096, 4096, device='cuda')
              duration = int(os.getenv('JOB_DURATION_SECS', '600'))
              for i in range(duration // 5):
                  _ = torch.mm(x, x)
                  if i % 12 == 0:
                      print(f"  inference running... {i*5}s elapsed")
                  time.sleep(5)
          env:
            - name: JOB_DURATION_SECS
              value: "600"
          resources:
            requests:
              nvidia.com/mig-2g.12gb: "1"
            limits:
              nvidia.com/mig-2g.12gb: "1"
EOF
```

Verify the job is running and on the 2g.12gb slice:

```bash
oc get pods -n inference-team-project -l demo/uc=uc9-time-based -o wide
```

```bash
oc logs -n inference-team-project -l demo/uc=uc9-time-based --tail=3
```

Expected:

```
WEEKDAY INFERENCE | GPU: NVIDIA A30 | VRAM: 11.9GB
Running on PREMIUM 2g.12gb slice (12GB) — weekday policy active
  inference running... 0s elapsed
```

Show the current quota state:

```bash
oc get clusterqueue inference-cluster-queue \
  -o jsonpath='{.status.flavorsUsage}' | python3 -m json.tool
```

Expected: `inUse: 1` for `nvidia.com/mig-2g.12gb`.

What to say: "Premium slice, in use, inference running. Now let's skip to Friday 6pm."

### Step 2: Trigger Weekend Policy Manually

What to say: "In production, the CronJob fires at 6pm every Friday. For the demo, I'll trigger it now. This creates a one-shot job from the CronJob — the same exact script."

```bash
oc create job \
  --from=cronjob/gpuaas-weekend-policy \
  weekend-now \
  -n gpuaas-system
```

Watch the policy job execute:

```bash
oc logs -n gpuaas-system \
  -l demo/policy=weekend -f
```

Expected log output — watch each step fire:

```
=== GPUaaS Weekend Policy: Fri May 10 18:00:01 UTC 2026 ===
Step 1: HoldAndDrain — Kueue evicts running 2g.12gb workloads
clusterqueue.kueue.x-k8s.io/inference-cluster-queue patched
Step 2: Waiting 45s for Kueue to drain...
Step 3: Set 2g.12gb nominalQuota to 0 — no premium GPU this weekend
clusterqueue.kueue.x-k8s.io/inference-cluster-queue patched
Step 4: Release hold — Kueue re-admits on 1g.6gb (quota still available)
clusterqueue.kueue.x-k8s.io/inference-cluster-queue patched
=== Weekend policy active: inference workloads now on 1g.6gb ===
```

### Step 3: Watch Kueue Drain the 2g.12gb Job

While the policy job runs, switch to watch the inference workload:

```bash
oc get workloads -n inference-team-project -w
```

Expected progression during the 45-second drain window:

```
NAME                      QUEUE           RESERVED IN            ADMITTED
uc9-inference-weekday-…   inference-queue inference-cluster-queue  True
uc9-inference-weekday-…   inference-queue <none>                   False    ← HoldAndDrain fired
uc9-inference-weekday-…   inference-queue inference-cluster-queue  True     ← re-admitted on 1g.6gb
```

```bash
oc get pods -n inference-team-project -l demo/uc=uc9-time-based -w
```

Expected — pod terminates, then new pod starts:

```
NAME                           READY   STATUS      AGE
uc9-inference-weekday-xxxxx    1/1     Running     45s
uc9-inference-weekday-xxxxx    0/1     Terminating 47s   ← Kueue evicted
uc9-inference-weekday-yyyyy    0/1     Pending     50s
uc9-inference-weekday-yyyyy    1/1     Running     53s   ← re-admitted on 1g.6gb
```

### Step 4: Confirm Job Is Now on 1g.6gb

```bash
oc logs -n inference-team-project \
  -l demo/uc=uc9-time-based --tail=5
```

The new pod will show it is requesting `mig-1g.6gb` with 6GB VRAM:

```bash
# Check what resource the current pod is consuming
oc get pod -n inference-team-project \
  -l demo/uc=uc9-time-based \
  -o jsonpath='{.items[0].spec.containers[0].resources}' | python3 -m json.tool
```

Expected — `nvidia.com/mig-1g.6gb: "1"` (not 2g.12gb):

```json
{
  "limits": {"nvidia.com/mig-1g.6gb": "1"},
  "requests": {"nvidia.com/mig-1g.6gb": "1"}
}
```

Show quota state — 2g.12gb is now zero:

```bash
oc get clusterqueue inference-cluster-queue \
  -o jsonpath='{.spec.resourceGroups}' | python3 -m json.tool
```

Expected — `nominalQuota: "0"` for `nvidia.com/mig-2g.12gb`:

```json
[
  {
    "flavors": [
      {
        "name": "a30-mig-2g12gb",
        "resources": [{"name": "nvidia.com/mig-2g.12gb", "nominalQuota": "0"}]
      },
      {
        "name": "a30-mig-1g6gb",
        "resources": [{"name": "nvidia.com/mig-1g.6gb", "nominalQuota": "1"}]
      }
    ]
  }
]
```

What to say: "The premium tier is closed for the weekend. Kueue moved the workload to the cheaper slice automatically. Alice's job is still running — on 1g.6gb instead of 2g.12gb. No ticket, no manual step, no forgotten GPU bill."

### Step 5: Restore Weekday Policy

What to say: "Now it's Monday 6am. The weekday CronJob fires and restores the premium quota."

```bash
oc create job \
  --from=cronjob/gpuaas-weekday-policy \
  weekday-now \
  -n gpuaas-system
```

Watch the restore:

```bash
oc logs -n gpuaas-system \
  -l demo/policy=weekday -f
```

Expected:

```
=== GPUaaS Weekday Policy: Mon May 13 06:00:01 UTC 2026 ===
Restoring 2g.12gb nominalQuota to 1 — premium GPU back for inference team
clusterqueue.kueue.x-k8s.io/inference-cluster-queue patched
=== Weekday policy active: inference workloads back on 2g.12gb ===
```

Verify the clusterqueue has restored quota:

```bash
oc get clusterqueue inference-cluster-queue \
  -o jsonpath='{.spec.resourceGroups}' | python3 -m json.tool
```

Expected: `nominalQuota: "1"` for `nvidia.com/mig-2g.12gb` again.

What to say: "Quota is back. If Alice's job is still in queue, Kueue will re-admit it on the premium slice on its next cycle. The CronJob was just the clock. Kueue owned every scheduling decision."

## Watch Commands

Run in separate terminals during Steps 2–4:

```bash
# Terminal 1: Workload state changes — the key view for HoldAndDrain
oc get workloads -n inference-team-project -w
```

```bash
# Terminal 2: Pod lifecycle — see eviction and re-admission
oc get pods -n inference-team-project -l demo/uc=uc9-time-based -w
```

```bash
# Terminal 3: Quota live view — watch 2g.12gb drop to 0 then restore
watch -n3 'echo "=== ClusterQueue Quota ===" && \
  oc get clusterqueue inference-cluster-queue \
  -o jsonpath="{.spec.resourceGroups}" | python3 -m json.tool'
```

```bash
# Terminal 4: Policy job logs
oc logs -n gpuaas-system -l demo/policy=weekend -f
```

## Key Message

> "Kueue enforces the time policy. The CronJob is just the clock. GPU cost optimization happens automatically."

## Cleanup

```bash
# Run from repo root:
bash cleanup.sh uc9
```
