# Hardware Guide — GPU Types and Node Roles

> **Testing note:** This repo was fully validated end-to-end on **NVIDIA A30 GPUs** only.
> All other GPU types are expected to work based on standard NVIDIA GPU Operator and
> mig-parted behavior, but have not been independently verified. If you test on a
> different GPU type, contributions to `lib/common.sh` and this guide are welcome.

---

## Supported GPU types

Set `GPU_TYPE` in `env.sh` to your exact GPU model and memory variant.

| GPU_TYPE | Memory | Architecture | Validated |
|---|---|---|---|
| `a30` | 24 GB | Ampere | ✅ Full end-to-end |
| `a100-40gb` | 40 GB | Ampere | Expected to work |
| `a100-80gb` | 80 GB | Ampere | Expected to work |
| `h100-80gb` | 80 GB | Hopper | Expected to work |
| `h100-nvl` | 94 GB | Hopper | Expected to work |
| `h200` | 141 GB | Hopper | Expected to work |
| `custom` | any | any | Manual config required |

> **Tip:** Verify your GPU's actual MIG resource names after setup:
> ```bash
> oc describe node <gpu-node> | grep nvidia.com/mig
> ```

---

## Node roles

Each GPU node is assigned a role that determines how its GPU(s) are partitioned.
Set via `MIG_STRATEGY` (all nodes) or `NODE_ROLES` (per node) in `env.sh`.

| Role | GPU[0] | GPU[1] | Min GPUs | Capability labels set |
|---|---|---|---|---|
| `small` | All small MIG slices | All small MIG slices | 1+ | `demo/gpu-has-small-mig=true` |
| `large` | All large MIG slices | All large MIG slices | 1+ | `demo/gpu-has-large-mig=true` |
| `dedicated` | Full GPU (no MIG) | Full GPU (no MIG) | 1+ | `demo/gpu-has-full=true` |
| `mixed` | All small MIG | Small + large MIG | 2+ | `demo/gpu-has-small-mig=true` + `demo/gpu-has-large-mig=true` |
| `full-combo` | All small MIG | Full GPU (no MIG) | 2+ | `demo/gpu-has-small-mig=true` + `demo/gpu-has-full=true` |

**`mixed` and `full-combo` require 2+ physical GPUs on the same node.**
On a single-GPU node, use `small`, `large`, or `dedicated`.

---

## MIG profiles per GPU type

Each role maps to a named profile in `mig-parted-config.yaml`.
The profile for your `GPU_TYPE` + role is selected automatically — no manual config needed.

> ✅ = validated on A30 | ⚪ = expected to work, not independently verified

| GPU_TYPE | `small` | `large` | `mixed` | `full-combo` | `dedicated` |
|---|---|---|---|---|---|
| `a30` ✅ | `all-1g.6gb` | `all-2g.12gb` | `mixed-a30` | `full-combo-a30` | `dedicated` |
| `a100-40gb` ⚪ | `all-1g.5gb` | `all-2g.10gb` | `mixed-a100-40gb` | `full-combo-a100-40gb` | `dedicated` |
| `a100-80gb` ⚪ | `all-1g.10gb` | `all-2g.20gb` | `mixed-a100-80gb` | `full-combo-a100-80gb` | `dedicated` |
| `h100-80gb` ⚪ | `all-1g.10gb` | `all-3g.40gb` | `mixed-h100-80gb` | `full-combo-h100-80gb` | `dedicated` |
| `h100-nvl` ⚪ | `all-1g.12gb` | `all-3g.47gb` | `mixed-h100-nvl` | `full-combo-h100-nvl` | `dedicated` |
| `h200` ⚪ | `all-1g.18gb` | `all-2g.35gb` | `mixed-h200` | `full-combo-h200` | `dedicated` |

`dedicated` disables MIG on all GPUs (`mig-enabled: false`) — same profile for all GPU types.

---

## MIG resource names per GPU type

These are the Kubernetes resource names exposed after MIG partitioning.
Kueue ClusterQueues and HardwareProfiles are configured with these automatically.

| GPU_TYPE | Small MIG resource | Large MIG resource | Full GPU resource |
|---|---|---|---|
| `a30` ✅ | `nvidia.com/mig-1g.6gb` | `nvidia.com/mig-2g.12gb` | `nvidia.com/gpu` |
| `a100-40gb` ⚪ | `nvidia.com/mig-1g.5gb` | `nvidia.com/mig-2g.10gb` | `nvidia.com/gpu` |
| `a100-80gb` ⚪ | `nvidia.com/mig-1g.10gb` | `nvidia.com/mig-2g.20gb` | `nvidia.com/gpu` |
| `h100-80gb` ⚪ | `nvidia.com/mig-1g.10gb` | `nvidia.com/mig-3g.40gb` | `nvidia.com/gpu` |
| `h100-nvl` ⚪ | `nvidia.com/mig-1g.12gb` | `nvidia.com/mig-3g.47gb` | `nvidia.com/gpu` |
| `h200` ⚪ | `nvidia.com/mig-1g.18gb` | `nvidia.com/mig-2g.35gb` | `nvidia.com/gpu` |

---

## Example: 3-node cluster with mixed topologies

```bash
# env.sh
GPU_TYPE=h100-80gb
MIG_STRATEGY=small             # default for unlisted nodes

# Get exact node names first:
#   oc get nodes -l nvidia.com/gpu.present=true

NODE_ROLES=(
  "worker-0.cluster.example.com:small"       # 1 GPU → uniform small slices
  "worker-1.cluster.example.com:dedicated"   # 1 GPU → full GPU, no MIG
  "worker-2.cluster.example.com:mixed"       # 2 GPUs → small + large simultaneously
)
```

After running `bash setup.sh`, validate with:
```bash
bash 02-gpu-setup/05-validation/validate-nodes.sh
```

Expected output:
```
NODE                               GPU-TYPE    MEMORY  ARCH    HAS-SMALL  HAS-LARGE  HAS-FULL
worker-0.cluster.example.com       h100-80gb   80gb    hopper  ✓          -          -
worker-1.cluster.example.com       h100-80gb   80gb    hopper  -          -          ✓
worker-2.cluster.example.com       h100-80gb   80gb    hopper  ✓          ✓          -
```

Kueue sees all three flavors (`h100-80gb-mig-1g10gb`, `h100-80gb-mig-3g40gb`, `h100-80gb-full`)
available across the cluster and schedules workloads to the appropriate node automatically.
