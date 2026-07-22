# UC1: Multiple GPU Types/Flavors (7 min)

## Story
Your organization has a heterogeneous GPU estate — economy MIG slices for everyday workloads, premium MIG slices for heavier inference, and full accelerators for large model deployments. Rather than giving every team access to every resource (and the chaos that follows), Red Hat OpenShift AI enforces a governed self-service model: each project sees exactly the GPU flavors it is entitled to, nothing more.

## What You're Showing
- Three distinct GPU "flavors" available on the platform: `1g.6gb` (economy MIG), `2g.12gb` (premium MIG), and full A30 (large model / DRA)
- Hardware profiles scoped per project — alice (inference) sees premium + full GPU, charlie (research) sees economy only, eve (analytics) sees CPU only
- The RHOAI dashboard hardware profile selector as the user-facing self-service surface
- Platform-enforced boundaries with zero manual ticket-filing by end users

## Setup
- All three users must have active RHOAI sessions (or browser tabs ready to switch)
- Confirm hardware profiles are applied: `oc get hardwareprofile -A`
- Confirm MIG slices are visible on both nodes before starting

## Demo Steps

### Step 1: Show the Platform Inventory
Start by showing the operator what is actually available on the cluster.

```bash
# List all hardware profiles across all namespaces
oc get hardwareprofile -A

# Confirm MIG capacity on Cluster B GPU 0 and GPU 1
oc get node -o json | jq '.items[] | {name: .metadata.name, mig: .status.capacity} | select(.mig | keys[] | startswith("nvidia.com/mig"))'
```

Expected output shows entries for `nvidia.com/mig-1g.6gb` (economy) and `nvidia.com/mig-2g.12gb` (premium) alongside `nvidia.com/gpu` for the full A30.

---

### Step 2: Log in as alice (Inference Team)
Switch to alice's browser tab and open the RHOAI dashboard.

**Say:** "Alice is on the inference team. When she goes to spin up a workbench, the platform already knows what she's allowed to use."

Navigate to: **RHOAI Dashboard > Data Science Projects > inference-team-project > Workbenches > Create Workbench**

In the **Hardware profile** dropdown, alice sees:
- `1g.6gb - Economy MIG Slice`
- `2g.12gb - Premium MIG Slice`
- `Full A30 - Large Model`

**Say:** "Three flavors, self-service, no ticket required."

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
# Describe a specific hardware profile to show the resource limits backing it
oc describe hardwareprofile mig-1g6gb -n redhat-ods-operator

# Show project-level binding
oc get hardwareprofile -n inference-team-project
oc get hardwareprofile -n research-team-project
oc get hardwareprofile -n analytics-project
```

Point out the `resources.requests` and `resources.limits` fields that map directly to the MIG slice resource names.

## Watch Commands
Run in a separate terminal throughout the demo:

```bash
# Live view of node GPU capacity (run once to snapshot)
watch -n 5 "oc get node -o custom-columns='NODE:.metadata.name,MIG-1G:.status.capacity.nvidia\.com/mig-1g\.6gb,MIG-2G:.status.capacity.nvidia\.com/mig-2g\.12gb,FULL-GPU:.status.capacity.nvidia\.com/gpu'"
```

## Key Message
> "GPU access is governed by the platform. Users self-serve within their allocated tier."

## Cleanup
```bash
# Run from repo root:
bash cleanup.sh uc1
```
