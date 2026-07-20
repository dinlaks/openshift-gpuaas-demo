# GPU-as-a-Service on OpenShift

A full working demo of GPU sharing governance on OpenShift using **Kueue**, **RHOAI**, and **ACM** — nine use cases showing how platform teams can enforce fair GPU sharing across multiple tenant teams without manual intervention.

> **Validated on:** NVIDIA A30 GPUs, OCP 4.21, RHOAI 3.3, Kueue stable-v1.3.
> Expected to work on A100, H100, H200 — set `GPU_TYPE` in `env.sh` accordingly.
> See [PREREQUISITES.md](PREREQUISITES.md) for full hardware and software requirements.

---

## Use cases

| # | Use Case | What it shows |
|---|---|---|
| UC1 | GPU Flavors | MIG slices vs full GPU — different tiers for different workloads |
| UC2 | MIG + DRA | Dynamic Resource Allocation for GPU scheduling (OCP 4.21+) |
| UC3 | Multi-Tenant Quotas | Per-team GPU quotas with cohort borrowing |
| UC4 | Queue-Based Scheduling | Jobs queue intelligently — never fail, never starve |
| UC5 | Priority + Preemption | High-priority jobs preempt lower-priority ones automatically |
| UC6 | Model Placement | Hardware profiles route workloads to the right GPU tier |
| UC7 | Global GPU Pool | MultiKueue dispatches across clusters transparently (add-on) |
| UC8 | Gang Scheduling | All-or-nothing batch scheduling — 4 GPUs or zero |
| UC9 | Time-Based Policy | CronJobs auto-switch GPU quota between weekday and weekend tiers |

---

## Quickstart

### 1. Clone and configure

```bash
git clone https://github.com/dinlaks/openshift-gpuaas-demo.git
cd openshift-gpuaas-demo
cp env.sh.example env.sh
```

Edit `env.sh` — minimum required:

```bash
OCP_API_URL=https://api.your-cluster.example.com:6443
OCP_USERNAME=gpuaas-admin
OCP_PASSWORD=<your-password>

GPU_TYPE=a30          # a30 | a100-40gb | a100-80gb | h100-80gb | h100-nvl | h200 | custom
MIG_ENABLED=true
MIG_STRATEGY=small
```

### 2. Run setup

```bash
bash setup.sh
```

This installs all operators, labels GPU nodes, configures MIG, deploys RBAC, hardware profiles, and Kueue queues in order. To skip already-installed operators:

```bash
bash setup.sh --skip-operators
```

### 3. Validate GPU resources

```bash
oc describe node <gpu-node> | grep nvidia.com/mig
```

### 4. Run a use case

Each use case is self-contained in `use-cases/`:

```bash
cd use-cases/uc3-multi-tenant
bash run-demo.sh

# Clean up when done
bash ../../cleanup.sh uc3
```

---

## Repository structure

```
openshift-gpuaas-demo/
├── env.sh.example          # All configuration — copy to env.sh
├── setup.sh                # Single-cluster setup orchestrator
├── cleanup.sh              # Tear down demo workloads by UC label
│
├── lib/
│   └── common.sh           # Shared functions; resolve_gpu_config() drives GPU vars
│
├── 01-operators/           # NFD, GPU Operator, Kueue, RHOAI operator installs
├── 02-gpu-setup/           # Node labels, MIG config, timeslicing, DRA, validation
├── 03-rbac/                # HTPasswd users, groups, namespaces, RHOAI auth
├── 04-hardware-profiles/   # RHOAI HardwareProfile CRs (GPU tier → workbench dropdown)
├── 05-kueue/               # ResourceFlavors, ClusterQueues, LocalQueues, priority classes
│
├── use-cases/              # One folder per UC — README + YAML jobs + run-demo.sh
│   ├── uc1-gpu-flavors/
│   ├── uc2-mig-dra/
│   ├── uc3-multi-tenant/
│   ├── uc4-queue-scheduling/
│   ├── uc5-priority-preemption/
│   ├── uc6-model-placement/
│   ├── uc8-gang-scheduling/
│   └── uc9-time-based-policy/
│
├── multi-cluster/          # Add-on: ACM + MultiKueue (UC7 global GPU pool)
│   ├── 01-acm-setup/
│   ├── 02-multikueue/
│   └── uc7-global-gpu-pool/
│
├── optional/
│   └── maas/               # Model-as-a-Service (RHOAI model serving)
│
└── docs/
    ├── architecture.md     # Architecture diagrams and component overview
    ├── hardware-guide.md   # GPU types, node roles, MIG profiles (all 30 combinations)
    └── grafana/            # DCGM Grafana dashboard JSON
```

---

## How GPU_TYPE drives the entire stack

Set one variable in `env.sh` — the entire stack adapts:

```bash
GPU_TYPE=h100-80gb
```

`resolve_gpu_config()` in `lib/common.sh` maps this to the correct resource names, Kueue flavor names, hardware profile requests, and MIG profiles per role — all substituted into YAML templates at deploy time via `envsubst`.

| GPU_TYPE | Memory | Small MIG resource | Large MIG resource |
|---|---|---|---|
| `a30` | 24 GB | `nvidia.com/mig-1g.6gb` | `nvidia.com/mig-2g.12gb` |
| `a100-40gb` | 40 GB | `nvidia.com/mig-1g.5gb` | `nvidia.com/mig-2g.10gb` |
| `a100-80gb` | 80 GB | `nvidia.com/mig-1g.10gb` | `nvidia.com/mig-2g.20gb` |
| `h100-80gb` | 80 GB | `nvidia.com/mig-1g.10gb` | `nvidia.com/mig-3g.40gb` |
| `h100-nvl` | 94 GB | `nvidia.com/mig-1g.12gb` | `nvidia.com/mig-3g.47gb` |
| `h200` | 141 GB | `nvidia.com/mig-1g.18gb` | `nvidia.com/mig-2g.35gb` |
| `custom` | any | set manually in env.sh | set manually in env.sh |

MIG profiles per role are resolved automatically based on `GPU_TYPE` and `MIG_STRATEGY`.

For the full reference — all 5 roles, 30 MIG profiles, and a multi-topology example:
**[docs/hardware-guide.md](docs/hardware-guide.md)**

---

## Multi-cluster add-on (UC7)

The multi-cluster add-on extends the single-cluster setup with cross-cluster GPU scheduling via MultiKueue and ACM. See [multi-cluster/README.md](multi-cluster/README.md).

---

## Cleanup

```bash
bash cleanup.sh uc4          # remove UC4 workloads only
bash cleanup.sh all          # remove all demo workloads
bash cleanup.sh all --hard   # also remove Kueue queues and hardware profiles
```

---

## Contributing

Issues and PRs welcome. If you validate this on a GPU type not listed, please open a PR updating `lib/common.sh` and `PREREQUISITES.md` with your findings.

---

## License

Copyright 2026 Dinesh Lakshmanan

Licensed under the [Apache License, Version 2.0](LICENSE).
