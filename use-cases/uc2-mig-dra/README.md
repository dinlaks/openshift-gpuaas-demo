# UC2: Dynamic Resource Allocation (DRA) — 10 min

## Story

Traditional GPU allocation hardcodes a resource name (`nvidia.com/gpu`) into the pod spec — developers must know the exact resource string, it never changes, and the GPU reservation persists for the pod's entire lifetime whether it's being used or not.

DRA changes the model: workloads describe **capability** (not name), Kubernetes creates a ResourceClaim dynamically at schedule time, binds it to the best matching device, and automatically deletes it when the workload finishes. The GPU returns to the pool instantly.

## What You're Showing

- **ResourceSlices** — every GPU and MIG slice published as a DRA device
- **DeviceClasses** — capability-based selectors (not resource names)
- **Live ResourceClaim lifecycle** — created dynamically, auto-deleted on completion
- **Full GPU DRA (Cluster A GPU 1)** — end-to-end working demo ✅
- **MIG DRA scheduling (Cluster A GPU 0)** — correct slice allocated ✅ | CDI injection has a known upstream driver bug (container sees full GPU — tracked in kubernetes-sigs/dra-driver-nvidia-gpu)

## Setup

Run this before the demo (takes ~2 min):

```bash
bash 02-gpu-setup/04-dra/deploy-dra.sh
```

This disables the device plugin, installs `dra-driver-nvidia-gpu v0.4.0`, and waits for ResourceSlices to appear.

Verify readiness:
```bash
oc get resourceslices
# Expected: 2 ResourceSlices (gpu.nvidia.com + compute-domain.nvidia.com)

oc get deviceclass
# Expected: nvidia-a30-gpu, nvidia-a30-mig-1g6gb, nvidia-a30-mig-2g12gb
```

---

## Demo Steps

### Step 1: Show the DRA Inventory (1 min)

**Say:** *"With DRA enabled, the cluster publishes every GPU device as a first-class resource. Let me show you what the scheduler sees."*

```bash
# Show devices inside the GPU ResourceSlice — what the scheduler sees
RS=$(oc get resourceslices -o name | grep 'gpu\.nvidia\.com' | grep -v compute)
oc get ${RS} -o jsonpath='{range .spec.devices[*]}{.name}{"\n"}{end}'
```

Point out: `gpu-1` (full A30, GPU 1) and `gpu-0-mig-1g6gb-14-0` through `14-3` (four MIG slices from GPU 0) — every schedulable device on this node, all in one place.

```bash
oc get deviceclass
```

**Say:** *"These DeviceClasses are capability selectors. `nvidia-a30-gpu` means 'any full A30'. `nvidia-a30-mig-1g6gb` means 'any MIG slice with 1g.6gb profile'. No hardcoded device names — pure capability description."*

---

### Step 2: Apply Demo Pod + Watch ResourceClaim Appear [KEY VISUAL — 2 panes]

**Open two terminal panes side by side.**

**Left pane** — start watching BEFORE applying:
```bash
oc get resourceclaim -n research-team-project -w
```

**Right pane** — apply the demo jobs:
```bash
oc apply -f 02-gpu-setup/04-dra/03-dra-demo-pod.yaml
```

Narrate as events appear in the left pane:
1. ResourceClaim appears → `allocated,reserved`
   - **Say:** *"Created automatically by Kubernetes the moment the pod was scheduled. No admin pre-allocated this."*
2. Jobs complete → ResourceClaim disappears
   - **Say:** *"Gone. Pod finished — claim deleted automatically. GPU is back in the pool."*

---

### Step 3: Show Pod Spec Live — CLI + Console

**While the pod is running**, show the ResourceClaimTemplate:
```bash
oc describe resourceclaimtemplate a30-gpu-claim -n research-team-project
```
Point out: `Device Class Name: nvidia-a30-gpu` — no `nvidia.com/gpu` string anywhere.

**In OpenShift Console:**
Navigate: **Workloads → Pods → namespace: research-team-project** → click `dra-gpu-job-xxxxx` → **YAML tab**

Search for `resourceClaims` in the YAML:
```yaml
resourceClaims:
  - name: gpu
    resourceClaimTemplateName: a30-gpu-claim
```

**Say:** *"No `nvidia.com/gpu` anywhere. Developer describes capability — same spec works on any cluster with an A30."*

Then click **Events tab** — shows the ResourceClaim being created and bound dynamically.

---

### Step 4: Show What Was Allocated (1 min)

```bash
oc describe resourceclaim -n research-team-project
```

Point out: which physical device was selected (`gpu-1`), the pod holding the claim, the DeviceClass that matched.

**Say:** *"Full audit trail — who has what GPU, which device, since when."*

---

### Step 5: Confirm GPU Output (30 sec)

After both jobs complete:
```bash
oc logs -n research-team-project -l demo/approach=dra
```

Expected output:
```
DRA: ResourceClaim created dynamically by Kubernetes at schedule time
GPU  : NVIDIA A30
VRAM : 25.3GB
No hardcoded resource name in pod spec.
DeviceClass selected this A30 by capability, not by name.
ResourceClaim will be deleted when this pod completes.
```

**Say:** *"The container got the full A30. DeviceClass drove the selection — no resource name in the pod spec."*

---

## Watch Commands (run in dedicated terminals during demo)

```bash
# Terminal 1 — watch ResourceClaims appear and disappear in real time
oc get resourceclaim -n research-team-project -w

# Terminal 2 — watch pod phase transitions
oc get pods -n research-team-project -l demo/uc=uc2-dra -w

# Terminal 3 — watch ResourceSlices (cluster-level DRA inventory)
watch -n 3 "oc get resourceslices"
```

---

## Known Limitation — MIG CDI Injection

The `dra-mig-job` correctly allocates a `1g.6gb` MIG slice via DRA (ResourceClaim shows `gpu-0-mig-1g6gb-14-0`), but the container sees the full GPU instead of the 6GB slice. Root cause: the DRA driver calls `GetDeviceSpecsByID` using the physical GPU UUID, but the management CDI spec only has MIG instance UUIDs — lookup returns empty, no device isolation applied. Tracked in `kubernetes-sigs/dra-driver-nvidia-gpu`. Not a DRA concept gap — the scheduling and allocation API works correctly.

For the live demo, focus on `dra-gpu-job` (full GPU) which is end-to-end validated.

---

## Key Messages

> *"DRA replaces resource names with capability descriptions. Workloads become portable — they don't care which cluster, which GPU model, which driver version. They describe what they need."*

> *"ResourceClaims are ephemeral — created on demand, deleted on completion. No wasted capacity sitting idle between jobs."*

> *"Traditional GPU request: reservation exists for the pod's entire lifetime. DRA: claim exists only while the workload actively needs it."*

---

## Cleanup

```bash
bash 02-gpu-setup/04-dra/teardown-dra.sh
```

This re-enables the device plugin for UC4/UC5/UC8 (which use MIG slices via device plugin).
