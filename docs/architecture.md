# Architecture Overview

## The problem this demo solves

Organizations buy expensive GPUs. Half sit idle. The other half are oversubscribed.
There is no visibility, no policy enforcement, and no fair sharing between teams.

This demo shows how **OpenShift + Kueue + RHOAI** solves that across ten use cases —
from basic GPU partitioning to cross-cluster workload dispatch and self-service booking.

---

## Architecture diagram

### Single-cluster setup (default)

```
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                         OpenShift Cluster                                │
  │                                                                          │
  │   Users                                                                  │
  │   alice (inference) ──┐                                                  │
  │   bob   (ds)          ├──► RHOAI Dashboard / oc CLI / API                │
  │   charlie (research)  │         │                                        │
  │   diana  (finetune) ──┘         │ job / workbench submit                 │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐                │
  │          │         Red Hat OpenShift AI (RHOAI)         │                │
  │          │  Hardware Profiles · Workbench UI · Notebooks│                │
  │          │  (profiles expose GPU tiers, not raw names)  │                │
  │          └──────────────────────┬───────────────────────┘                │
  │                                 │ workload admission                     │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐                │
  │          │              Kueue Scheduler                 │                │
  │          │                                              │                │
  │          │  inference-queue ──► inference-cluster-queue │                │
  │          │  ds-queue        ──► ds-cluster-queue        │                │
  │          │  research-queue  ──► research-cluster-queue  │  gpuaas-       │
  │          │  finetune-queue  ──► finetune-cluster-queue  │  cohort        │
  │          │  analytics-queue ──► analytics-cluster-queue │  (borrowing)   │
  │          │                                              │                │
  │          │  Priority · Preemption · Gang scheduling     │                │
  │          │  Time-based policy (CronJobs)                │                │
  │          └──────────────────────┬───────────────────────┘                │
  │                                 │ pod scheduled                          │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐                │
  │          │              GPU Worker Node                 │                │
  │          │      (layout adapts to GPU_TYPE in env.sh)   │                │
  │          │                                              │                │
  │          │  Small GPU Tier  (MIG slice or timeslice)    │                │
  │          │  ┌──────────┐ ┌──────────┐ ┌──────────┐      │                │
  │          │  │  small   │ │  small   │ │  small   │      │                │
  │          │  │  tier    │ │  tier    │ │  tier .. │      │                │
  │          │  │  (bob)   │ │(charlie) │ │  (idle)  │      │                │
  │          │  └──────────┘ └──────────┘ └──────────┘      │                │
  │          │                                              │                │
  │          │  Large GPU Tier  (large MIG or full GPU)     │                │
  │          │  ┌──────────────────────────────────────┐    │                │
  │          │  │  large tier (alice / diana)           │   │                │
  │          │  │  OR full GPU for DRA / large models   │   │                │
  │          │  └──────────────────────────────────────┘    │                │
  │          │                                              │                │
  │          │  NVIDIA GPU Operator · DCGM metrics · NFD    │                │
  │          └──────────────────────────────────────────────┘                │
  │                                                                          │
  └──────────────────────────────────────────────────────────────────────────┘
```

> **GPU_TYPE resolution:** The abstract tiers above map to concrete resource names
> based on `GPU_TYPE` in `env.sh`. For example:
>
> | GPU_TYPE | Small tier resource | Large tier resource |
> |---|---|---|
> | `a30` | `nvidia.com/mig-1g.6gb` | `nvidia.com/mig-2g.12gb` |
> | `a100-40gb` | `nvidia.com/mig-1g.5gb` | `nvidia.com/mig-2g.10gb` |
> | `h100-80gb` | `nvidia.com/mig-1g.10gb` | `nvidia.com/mig-3g.40gb` |
> | `h200` | `nvidia.com/mig-1g.18gb` | `nvidia.com/mig-2g.35gb` |
>
> `resolve_gpu_config()` in `lib/common.sh` performs this resolution at runtime.
> You never hardcode resource names in YAML — they are injected via `envsubst`.

### Multi-cluster setup (optional add-on — UC7)

```
  ┌─────────────────────────────┐         ┌─────────────────────────────┐
  │      Cluster A (Hub)        │         │      Cluster B (Spoke)      │
  │                             │         │                             │
  │  ACM Hub                    │◄───────►│  ACM Spoke                  │
  │  Kueue (manager)            │         │  Kueue (worker)             │
  │  MultiKueue                 │         │                             │
  │                             │         │  inference-team-project     │
  │  global-gpu-queue           │─ dispatch──►  (shadow job created)    │
  │   └─► MultiKueue selects    │         │                             │
  │        cluster with capacity│         │  GPU Worker Node            │
  │                             │         │  (same GPU setup)           │
  └─────────────────────────────┘         └─────────────────────────────┘
         ▲
         │  Users submit here only
         │  (never choose a cluster)
         │
    alice, bob, charlie...
```

---

## Component stack

```
┌─────────────────────────────────────────────────────────┐
│  Red Hat OpenShift AI (RHOAI) 3.5                       │
│  • Workbench UI  • Hardware Profiles  • Model Serving   │
├─────────────────────────────────────────────────────────┤
│  Kueue (Red Hat build) stable-v1.3                      │
│  • ClusterQueues  • LocalQueues  • Cohort borrowing     │
│  • Priority + Preemption  • Gang scheduling             │
│  • Time-based policy (CronJobs)                         │
├─────────────────────────────────────────────────────────┤
│  NVIDIA GPU Operator                                    │
│  • MIG partitioning  • Timeslicing  • DRA (OCP 4.21+)   │
│  • DCGM metrics  • Node Feature Discovery               │
│  GPU_TYPE: a30 · a100-40gb · a100-80gb · h100-80gb      │
│            h100-nvl · h200 · custom                     │
│  Resource names + MIG profiles resolved from GPU_TYPE   │
├─────────────────────────────────────────────────────────┤
│  OpenShift Container Platform 4.17+                     │
│  • RBAC / namespaces  • Priority classes                │
│  • ACM (multi-cluster add-on)                           │
└─────────────────────────────────────────────────────────┘
```

---

## Demo user personas

| User | Namespace | GPU tier | Queue | Priority |
|---|---|---|---|---|
| alice | inference-team-project | Large MIG / Full GPU | inference-cluster-queue | high |
| bob | ds-team-project | Small MIG | ds-cluster-queue | medium |
| charlie | research-team-project | Small MIG | research-cluster-queue | medium |
| diana | finetune-team-project | Large MIG | finetune-cluster-queue | medium |
| eve | analytics-project | CPU only | analytics-cluster-queue | low |
| gpuaas-admin | all | all | all | cluster-admin |

---

## Kueue quota model

All ClusterQueues share a **cohort** (`gpuaas-cohort`).

- `nominalQuota` — guaranteed allocation for that team
- `borrowingLimit` — how much extra the team can take from idle cohort quota
- Preemption — higher-priority workloads can evict lower-priority ones

```
gpuaas-cohort
├── inference-cluster-queue  nominalQuota: 1 large-tier + 1 full-gpu + 1 small-tier
├── ds-cluster-queue         nominalQuota: 2 small-tier,   borrowingLimit: 2
├── research-cluster-queue   nominalQuota: 1 small-tier,   borrowingLimit: 3
├── finetune-cluster-queue   nominalQuota: 0 large-tier,   borrowingLimit: 1
└── analytics-cluster-queue  nominalQuota: CPU only
```

> "small-tier" and "large-tier" are logical labels. The actual Kubernetes resource
> name (e.g., `nvidia.com/mig-1g.6gb` for A30, `nvidia.com/mig-1g.10gb` for H100)
> is resolved from `GPU_TYPE` at setup time via `resolve_gpu_config()` in `lib/common.sh`.

---

## GPU partitioning options

Choose one mode per node. Set in `env.sh` before running setup.

| Mode | env.sh setting | Best for |
|---|---|---|
| MIG (recommended) | `MIG_STRATEGY=small (or mixed, full-combo)` | Hard memory isolation between teams |
| Timeslicing | `MIG_STRATEGY=dedicated` + configure `03-timeslicing/` | Older GPUs without MIG support |
| Full GPU | `MIG_STRATEGY=dedicated` | Large model inference, DRA demos |
