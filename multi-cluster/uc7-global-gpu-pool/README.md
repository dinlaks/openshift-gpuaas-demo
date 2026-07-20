# UC7: Global GPU Pools Across Clusters (10 min)

## Story

Two OpenShift clusters — managed as a single platform. ACM governs the fleet: identical GPU configuration, identical Kueue flavors, identical policy on both clusters. When Cluster A's premium GPU slice fills up, Kueue's MultiKueue automatically dispatches to Cluster B — without the user specifying a cluster, without resubmitting, without manual intervention. The platform finds the capacity.

## What You're Showing

- ACM policy enforcing identical GPU configuration across both clusters (fleet governance)
- ACM Observability surfacing unified DCGM GPU metrics from both clusters
- MultiKueue automatically dispatching to Cluster B when Cluster A's 2g.12gb quota is exhausted
- The user submits to one queue — the platform picks the cluster

## Setup

Verify ACM and MultiKueue are operational:

```bash
# ACM hub status
oc get managedcluster
oc get policy gpuaas-gpu-config-policy -n open-cluster-management

# MultiKueue admission check
oc get admissioncheck multikueue-check
oc get multikueuecluster
```

Verify Cluster A's inference quota is NOT already full:

```bash
oc get clusterqueue inference-cluster-queue -o jsonpath='{.status.flavorsUsage}' | python3 -m json.tool
```

If 2g.12gb is already consumed, delete any lingering inference jobs before starting:

```bash
oc delete jobs -n inference-team-project -l demo/uc=uc7-multi-cluster --ignore-not-found
```

## Demo Steps

### Act 1 (3 min): ACM Fleet Governance

#### Step 1: Show Both Clusters Under ACM Management

What to say: "This is the hub. ACM manages both clusters from here. Let's look at the fleet."

```bash
oc get managedcluster -o wide
```

Expected:

```
NAME        HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
cluster-a   true           https://api.cluster-a…  True     True        5d
cluster-b   true           https://api.cluster-b…  True     True        5d
```

#### Step 2: Show the GPU Config Policy

What to say: "ACM enforces a single GPU policy across the entire fleet. This policy governs MIG configuration, GPU Operator installation, and Kueue ResourceFlavors. Both clusters must be identical — or ACM remediates them."

```bash
oc get policy gpuaas-gpu-config-policy -n open-cluster-management
```

Expected:

```
NAME                      REMEDIATION ACTION   COMPLIANCE STATE   AGE
gpuaas-gpu-config-policy  enforce              Compliant          5d
```

```bash
# Show policy details — governance templates
oc describe policy gpuaas-gpu-config-policy -n open-cluster-management | grep -A5 "Policy Templates"
```

```bash
# Show per-cluster compliance
oc get policy gpuaas-gpu-config-policy -n open-cluster-management \
  -o jsonpath='{.status.status}' | python3 -m json.tool
```

Expected output showing both clusters Compliant:

```json
[
  {"clustername": "cluster-a", "clusternamespace": "cluster-a", "compliant": "Compliant"},
  {"clustername": "cluster-b", "clusternamespace": "cluster-b", "compliant": "Compliant"}
]
```

What to say: "Both clusters are Compliant. ACM verified that GPU Operator is installed, MIG is configured identically, and Kueue ResourceFlavors match — on both clusters. If cluster-b drifted, ACM would auto-remediate it within 60 seconds."

---

### Act 2 (2 min): ACM Observability — Unified GPU Metrics

What to say: "ACM Observability aggregates DCGM metrics from both clusters into a single view. We can see GPU utilization across all GPUs from one dashboard."

Open the ACM Observability console (Grafana):
- Navigate to: ACM Console → Observe → Grafana → GPU Utilization dashboard
- Show the DCGM panel with metrics from both `cluster-a` and `cluster-b`

```bash
# Confirm Observability is collecting from both clusters
oc get multiclusterobservability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected: `True`

What to say: "One pane of glass for all four GPUs across two physical servers. GPU utilization, memory pressure, temperature — all from one ACM Observability dashboard."

---

### Act 3 (5 min): MultiKueue Cross-Cluster Dispatch

#### Step 3: Fill Cluster A's 2g.12gb Quota

What to say: "Now let's show the real power. I'm going to fill Cluster A's premium GPU slot with a local inference job."

```bash
oc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: uc7-cluster-a-filler
  namespace: inference-team-project
  labels:
    demo/uc: uc7-filler
  annotations:
    kueue.x-k8s.io/queue-name: inference-queue
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        demo/uc: uc7-filler
    spec:
      restartPolicy: Never
      containers:
        - name: filler
          image: pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime
          command: [python, -c, "import time; print('Holding Cluster A 2g.12gb slot'); time.sleep(3600)"]
          resources:
            requests:
              nvidia.com/mig-2g.12gb: "1"
            limits:
              nvidia.com/mig-2g.12gb: "1"
EOF
```

```bash
# Verify Cluster A's 2g.12gb quota is now full
oc get clusterqueue inference-cluster-queue \
  -o jsonpath='{.status.flavorsUsage}' | python3 -m json.tool
```

Expected — `inUse: 1`, `nominalQuota: 1` for `a30-mig-2g12gb`:

```json
[{"name": "${MIG_LARGE_FLAVOR}", "resources": [{"borrowed": "0", "inUse": "1", "name": "nvidia.com/mig-2g.12gb"}]}]
```

#### Step 4: Submit to the Global Queue — MultiKueue Picks Cluster B

What to say: "Cluster A is full. Now I submit a second inference job to the global-gpu-queue — this is the MultiKueue-enabled queue. Watch what happens."

```bash
oc apply -f multi-cluster/02-multikueue/07-uc7-demo-job.yaml
```

```bash
# Watch the workload status — it will show MultiKueue dispatching to cluster-b
oc get workloads -n inference-team-project -w
```

Expected progression:

```
NAME                    QUEUE          RESERVED IN   ADMITTED   AGE
global-inference-job-…  global-queue   <none>        False      5s
global-inference-job-…  global-queue   cluster-b     True       12s
```

What to say: "Cluster A was full. MultiKueue checked Cluster B — found the 2g.12gb slice free — and dispatched there. The user submitted once to `global-gpu-queue`. The platform picked the cluster."

#### Step 5: Confirm Job Running on Cluster B

```bash
# View job on Cluster B (spoke)
oc get jobs -n inference-team-project --context cluster-b
oc get pods -n inference-team-project --context cluster-b -o wide
```

Expected: pod running on a cluster-b node.

```bash
# Read the job output — confirms it's on Cluster B's hardware
oc logs -n inference-team-project --context cluster-b \
  -l demo/uc=uc7-multi-cluster
```

Expected:

```
============================================================
UC7: GLOBAL GPU POOL — CROSS-CLUSTER DISPATCH
============================================================
Running on node : cluster-b-node-1
GPU             : (your GPU type)
GPU Memory      : 11.9 GB  (2g.12gb MIG slice)
Cluster A full  : Job dispatched to Cluster B by MultiKueue
============================================================
```

What to say: "Same GPU, different cluster. The user never specified a cluster. Kueue found the capacity and placed the job. This is what a global GPU pool looks like."

## Watch Commands

Run in separate terminals during Act 3:

```bash
# Terminal 1: Watch workloads on the hub
oc get workloads -n inference-team-project -w
```

```bash
# Terminal 2: Watch jobs appear on Cluster B
watch -n3 'echo "=== Cluster B Jobs ===" && oc get jobs -n inference-team-project --context cluster-b && echo "" && echo "=== Cluster B Pods ===" && oc get pods -n inference-team-project --context cluster-b -o wide'
```

```bash
# Terminal 3: Monitor quota usage on Cluster A
watch -n3 'echo "=== Cluster A ClusterQueue ===" && oc get clusterqueue inference-cluster-queue -o jsonpath="{.status.flavorsUsage}" | python3 -m json.tool'
```

## Key Message

> "ACM governs the fleet. Kueue schedules across it. Submit once — the platform picks the cluster."

## Cleanup

```bash
bash cleanup.sh uc7
```
