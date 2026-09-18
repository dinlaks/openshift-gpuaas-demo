# UC1: Multiple GPU Types/Flavors

> **Demo Recording:** [▶ Watch on YouTube](https://youtu.be/BU0Hc7oaKFU) — narrated live demo on a real cluster, no login required.


## Story
Your organization has a heterogeneous GPU estate — economy MIG slices for everyday workloads, premium MIG slices for heavier inference, and full accelerators for large model deployments. Rather than giving every team access to every resource (and the chaos that follows), Red Hat OpenShift AI enforces a governed self-service model: each project sees exactly the GPU flavors it is entitled to, nothing more.

## What You're Showing
- Three distinct GPU "flavors" available on the platform: `1g.6gb` (economy MIG), `2g.12gb` (premium MIG), and full A30 (large model / DRA)
- Hardware profiles scoped per project — alice (inference) sees large MIG slice + full GPU, charlie (research) sees small MIG slice only, eve (analytics) sees CPU only
- The RHOAI dashboard hardware profile selector as the user-facing self-service surface
- Platform-enforced boundaries with zero manual ticket-filing by end users

## Setup
- All three users must have active RHOAI sessions (or browser tabs ready to switch)
- Confirm hardware profiles are applied: `oc get hardwareprofile -A`
- Confirm MIG slices are visible on both nodes before starting

## Demo Steps

> **Dashboard setup (open before starting):** Keep one RHOAI Dashboard tab open — Tab 1 only (Tab 2 not needed for this UC, which is a hardware profile walkthrough with no workload submissions):
> - **Tab 1 — Observe & Monitor > Infrastructure**: GPU capacity, queue allocation, hardware usage

### Step 1: Show the Platform Inventory
Start by opening the GPUaaS Infrastructure dashboard to show real-time cluster GPU capacity.

Switch to **Tab 1 (Infrastructure)**

**Say:** "Before we look at individual project restrictions, here's the full picture — every GPU resource on this cluster, live. This is what the platform team sees at all times."

Point out each section:
- **Summary**: "Total accelerators — the count of GPU slices this cluster has available. Compute and memory consumption are our real-time utilization gauges — right now idle, but these fill as teams submit workloads."
- **Hardware usage**: "The bar shows available vs in-use accelerators grouped by GPU model. One hardware type, governed across five teams."
- **Cluster queue consumption**: Scroll to `gpuaas-cohort` — "Accelerators across 4 cluster queues, all available to borrow. Every queue has a guaranteed slice — ds, finetune, inference, research. Each card shows active/pending workloads and per-queue utilization live."

Then confirm via CLI:

```bash
# List all hardware profiles across all namespaces
oc get hardwareprofile -A

# Confirm MIG capacity on GPU 0 and GPU 1 on the cluster
oc get node -o json | jq '.items[] | {name: .metadata.name, mig: .status.capacity} | select(.mig | keys[] | startswith("nvidia.com/mig"))'
```

Expected output shows entries for `nvidia.com/mig-1g.6gb` (economy) and `nvidia.com/mig-2g.12gb` (premium) alongside `nvidia.com/gpu` for the full A30.

---

### Step 2: Log in as alice (Inference Team)
Switch to alice's browser tab and open the RHOAI dashboard.

**Say:** "Alice is on the inference team. When she goes to spin up a workbench, the platform already knows what she's allowed to use."

Navigate to: **RHOAI Dashboard > Data Science Projects > inference-team-project > Workbenches > Create Workbench**

In the **Hardware profile** dropdown, alice sees:
- `2g.12gb - Premium MIG Slice` (Large Slice)
- `Full GPU` (dedicated full accelerator)

**Say:** "Two premium tiers, self-service, no ticket required. Alice is inference team — she gets the high-end slices. The economy tier is invisible to her."

---

### Step 3: Log in as charlie (Research Team)
Switch to charlie's browser tab.

**Say:** "Charlie is on the research team — a different budget tier. Watch what happens in his hardware selector."

Navigate to: **RHOAI Dashboard > Data Science Projects > research-team-project > Workbenches > Create Workbench**

In the **Hardware profile** dropdown, charlie sees only:
- `1g.6gb - Economy MIG Slice`

**Say:** "The premium slice and the full A30 are invisible to charlie. He can't request what the platform hasn't granted him. This is policy, not honour system."

---

### Step 4: Log in as eve (Analytics — CPU Only)
Switch to eve's browser tab.

Navigate to: **RHOAI Dashboard > Data Science Projects > analytics-project > Workbenches > Create Workbench**

In the **Hardware profile** dropdown, eve sees:
- `CPU - No GPU`

**Say:** "Eve's team runs analytics workloads that don't need a GPU. Her project has a CPU-only profile — she never accidentally consumes a scarce accelerator."

---

### Step 5: Confirm via CLI (operator view)
Return to the admin terminal.

```bash
# Describe a hardware profile to show the Kueue queue binding and resource limits
oc get hardwareprofile gpu-mig-small -n ds-team-project -o yaml
oc get hardwareprofile gpu-full -n inference-team-project -o yaml

# Show project-level binding
oc get hardwareprofile -n inference-team-project
oc get hardwareprofile -n research-team-project
oc get hardwareprofile -n analytics-project
```

Point out `spec.identifiers` (the GPU resource limits) and `spec.scheduling.kueue.localQueueName` (the Kueue queue that enforces admission and routes to the correct GPU node via ResourceFlavor).

## Watch Commands
Run in a separate terminal throughout the demo:

```bash
# Live view of node GPU capacity (run once to snapshot)
watch -n 5 "oc get node -o custom-columns='NODE:.metadata.name,MIG-1G:.status.capacity.nvidia\.com/mig-1g\.6gb,MIG-2G:.status.capacity.nvidia\.com/mig-2g\.12gb,FULL-GPU:.status.capacity.nvidia\.com/gpu'"
```

## Key Message
> "GPU access is governed by the platform. Users self-serve within their allocated tier."

## Cleanup

UC1 is a dashboard walkthrough — no Kueue workloads are submitted. No cleanup required.
