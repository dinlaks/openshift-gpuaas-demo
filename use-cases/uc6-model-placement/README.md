# UC6: Model-Specific Placement (7 min)

## Story

Large models need large GPU memory — you cannot fit a 13B parameter model on a 6GB slice. This platform routes workloads to the right GPU automatically based on the model's memory requirements: full A30 (24GB) for production inference, 1g.6gb MIG slices for development and small models. The hardware profile in the RHOAI dashboard is the policy — users select their profile, and placement is enforced.

## What You're Showing

- Hardware profiles in RHOAI enforce GPU selection — users cannot accidentally pick the wrong GPU tier
- A job requesting a full A30 lands on Cluster A GPU 1 (non-MIG, 24GB)
- A job requesting 1g.6gb lands on GPU 0 (MIG, 6GB slice)
- `nodeSelector` in the hardware profile is the mechanism — not hope, not documentation

## Setup

Ensure both hardware profiles exist:

```bash
oc get hardwareprofile -n inference-team-project
oc get hardwareprofile -n research-team-project
```

Verify GPU nodes are labeled correctly:

```bash
oc get nodes -l nvidia.com/gpu.present=true -o custom-columns='NAME:.metadata.name,HAS-FULL:.metadata.labels["demo/gpu-has-full"],HAS-SMALL:.metadata.labels["demo/gpu-has-small-mig"]'
```

Expected: Cluster A node shows `gpu-gpu1-mode=full` and `gpu-mode=mig-mixed`.

## Demo Steps

### Step 1: Show the Hardware Profiles in RHOAI Dashboard

What to say: "Platform operators define hardware profiles — these are the GPU tiers available to data scientists. Each profile enforces a nodeSelector. Users pick the tier they need; placement is automatic."

Open the RHOAI dashboard → Settings → Hardware Profiles. Show two profiles:
- **A30 GPU — Full (24GB, Non-MIG)** — scoped to `inference-team-project`
- **A30 MIG — 1g.6gb (Small Slice)** — scoped to `research-team-project`

Then show the YAML behind each profile:

```bash
oc get hardwareprofile gpu-a30-full -n inference-team-project -o yaml
```

Point out the `scheduling.nodeSelector`:

```yaml
scheduling:
  nodeSelector:
    demo/gpu-has-full: "true"
    demo/gpu-type: a30
```

```bash
oc get hardwareprofile gpu-a30-mig-1g6gb -n research-team-project -o yaml
```

Point out the contrast:

```yaml
scheduling:
  nodeSelector:
    demo/gpu-has-small-mig: "true"
```

### Step 2: Submit a Job Targeting the Full A30

What to say: "Alice's inference team needs the full 24GB A30 for a large model. She selects the 'Full A30' hardware profile. Let's watch where the pod lands."

```bash
oc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: uc6-large-model-inference
  namespace: inference-team-project
  labels:
    demo/uc: uc6-placement
    demo/model-size: large
  annotations:
    kueue.x-k8s.io/queue-name: inference-queue
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        demo/uc: uc6-placement
        demo/model-size: large
    spec:
      restartPolicy: Never
      nodeSelector:
        demo/gpu-has-full: "true"
        demo/gpu-type: a30
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: large-model
          image: pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime
          command: [python, -c]
          args:
            - |
              import torch, socket
              node = socket.gethostname()
              gpu = torch.cuda.get_device_name(0)
              mem = torch.cuda.get_device_properties(0).total_memory / 1e9
              print(f"Node     : {node}")
              print(f"GPU      : {gpu}")
              print(f"VRAM     : {mem:.1f} GB  (full A30, no MIG)")
              print("UC6: Large model inference — correctly placed on full A30 24GB")
          resources:
            requests:
              nvidia.com/gpu: "1"
            limits:
              nvidia.com/gpu: "1"
EOF
```

### Step 3: Verify Pod Lands on the Full A30 Node

```bash
oc get pods -n inference-team-project -l demo/uc=uc6-placement -o wide
```

Expected output — note the node and that it runs on GPU 1 (non-MIG):

```
NAME                         READY   STATUS    NODE              ...
uc6-large-model-inference-… Running  cluster-a-node-1  ...
```

```bash
oc logs -n inference-team-project -l demo/uc=uc6-placement,demo/model-size=large
```

Expected:

```
Node     : cluster-a-node-1
GPU      : NVIDIA A30
VRAM     : 23.7 GB  (full A30, no MIG)
UC6: Large model inference — correctly placed on full A30 24GB
```

### Step 4: Submit a Job Targeting the Small 1g.6gb MIG Slice

What to say: "Charlie's research team is experimenting — they only need a 6GB slice. Different hardware profile, different GPU. Same cluster, different GPU."

```bash
oc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: uc6-small-model-dev
  namespace: research-team-project
  labels:
    demo/uc: uc6-placement
    demo/model-size: small
  annotations:
    kueue.x-k8s.io/queue-name: research-queue
spec:
  parallelism: 1
  completions: 1
  template:
    metadata:
      labels:
        demo/uc: uc6-placement
        demo/model-size: small
    spec:
      restartPolicy: Never
      nodeSelector:
        demo/gpu-has-small-mig: "true"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: small-model
          image: pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime
          command: [python, -c]
          args:
            - |
              import torch, socket
              node = socket.gethostname()
              gpu = torch.cuda.get_device_name(0)
              mem = torch.cuda.get_device_properties(0).total_memory / 1e9
              print(f"Node     : {node}")
              print(f"GPU      : {gpu}")
              print(f"VRAM     : {mem:.1f} GB  (1g.6gb MIG slice)")
              print("UC6: Small model dev — correctly placed on 1g.6gb MIG slice")
          resources:
            requests:
              nvidia.com/mig-1g.6gb: "1"
            limits:
              nvidia.com/mig-1g.6gb: "1"
EOF
```

### Step 5: Compare Placement Side by Side

```bash
oc get pods -n inference-team-project -l demo/uc=uc6-placement -o wide
oc get pods -n research-team-project -l demo/uc=uc6-placement -o wide
```

What to say: "Same physical node, different GPU. The full A30 job landed on GPU 1 (24GB, non-MIG). The small model landed on a 1g.6gb MIG slice on GPU 0. The hardware profile encoded this decision — the user just picked a tier."

Check logs for the small model:

```bash
oc logs -n research-team-project -l demo/uc=uc6-placement,demo/model-size=small
```

Expected:

```
Node     : cluster-a-node-1
GPU      : NVIDIA A30
VRAM     : 5.8 GB  (1g.6gb MIG slice)
UC6: Small model dev — correctly placed on 1g.6gb MIG slice
```

### Step 6: Show the RHOAI Dashboard Profile Enforcement

What to say: "This is the key insight. The data scientist never wrote a nodeSelector. They selected a hardware profile from a dropdown. The platform encoded the placement policy. Model placement is policy — not prayer."

Navigate in RHOAI dashboard:
- Settings → Hardware Profiles → show both profiles are active
- Click into each profile — show the node selector fields are greyed out to end users

## Watch Commands

Run in a separate terminal during the demo:

```bash
# Watch both jobs placed simultaneously
watch -n2 'echo "=== Full A30 (inference-team-project) ===" && \
  oc get pods -n inference-team-project -l demo/uc=uc6-placement -o wide && \
  echo "" && \
  echo "=== 1g.6gb MIG (research-team-project) ===" && \
  oc get pods -n research-team-project -l demo/uc=uc6-placement -o wide'
```

```bash
# Show node GPU labels to confirm hardware topology
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns='NODE:.metadata.name,HAS-FULL:.metadata.labels["demo/gpu-has-full"],HAS-SMALL:.metadata.labels["demo/gpu-has-small-mig"]'
```

## Key Message

> "Model placement is policy, not prayer. The platform matches workload to GPU capability automatically — the data scientist picks a tier, the hardware profile does the rest."

## Cleanup

```bash
# Run from repo root:
bash cleanup.sh uc6
```
