# Architecture Overview

## The problem this demo solves

Organizations buy expensive GPUs. Half sit idle. The other half are oversubscribed.
There is no visibility, no policy enforcement, and no fair sharing between teams.

This demo shows how **OpenShift + Kueue + RHOAI** solves that across nine use cases —
from basic GPU partitioning to cross-cluster workload dispatch.

---

## Architecture diagram

### Single-cluster setup (default)

```
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                         OpenShift Cluster                                │
  │                                                                          │
  │   Users                                                                  │
  │   alice (inference) ──┐                                                  │
  │   bob   (ds)          ├──► RHOAI Dashboard / oc CLI / API               │
  │   charlie (research)  │         │                                        │
  │   diana  (finetune) ──┘         │ job / workbench submit                │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐               │
  │          │         Red Hat OpenShift AI (RHOAI)         │               │
  │          │  Hardware Profiles · Workbench UI · Notebooks│               │
  │          └──────────────────────┬───────────────────────┘               │
  │                                 │ workload admission                     │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐               │
  │          │              Kueue Scheduler                  │               │
  │          │                                              │               │
  │          │  inference-queue ──► inference-cluster-queue │               │
  │          │  ds-queue        ──► ds-cluster-queue        │               │
  │          │  research-queue  ──► research-cluster-queue  │  gpuaas-      │
  │          │  finetune-queue  ──► finetune-cluster-queue  │  cohort       │
  │          │  analytics-queue ──► analytics-cluster-queue │  (borrowing)  │
  │          │                                              │               │
  │          │  Priority · Preemption · Gang scheduling     │               │
  │          │  Time-based policy (CronJobs)                │               │
  │          └──────────────────────┬───────────────────────┘               │
  │                                 │ pod scheduled                          │
  │                                 ▼                                        │
  │          ┌──────────────────────────────────────────────┐               │
  │          │              GPU Worker Node                  │               │
  │          │                                              │               │
  │          │  GPU 0 (MIG partitioned)                     │               │
  │          │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌────┐│               │
  │          │  │ small   │ │ small   │ │ small   │ │    ││               │
  │          │  │ MIG     │ │ MIG     │ │ MIG     │ │ .. ││               │
  │          │  │ (bob)   │ │(charlie)│ │ (idle)  │ │    ││               │
  │          │  └─────────┘ └─────────┘ └─────────┘ └────┘│               │
  │          │                                              │               │
  │          │  GPU 1 (full GPU or MIG-mixed)               │               │
  │          │  ┌──────────────────────────────────────┐   │               │
  │          │  │  large MIG slice (alice/diana)        │   │               │
  │          │  │  OR full GPU for DRA / large models   │   │               │
  │          │  └──────────────────────────────────────┘   │               │
  │          │                                              │               │
  │          │  NVIDIA GPU Operator · DCGM metrics · NFD   │               │
  │          └──────────────────────────────────────────────┘               │
  │                                                                          │
  └──────────────────────────────────────────────────────────────────────────┘
```

### Multi-cluster setup (optional add-on — UC7)

```
  ┌─────────────────────────────┐         ┌─────────────────────────────┐
  │      Cluster A (Hub)        │         │      Cluster B (Spoke)      │
  │                             │         │                             │
  │  ACM Hub                    │◄───────►│  ACM Spoke                  │
  │  Kueue (manager)            │         │  Kueue (worker)             │
  │  MultiKueue                 │         │                             │
  │                             │         │  inference-team-project     │
  │  global-gpu-queue           │─ dispatch──►  (shadow job created)   │
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
│  Red Hat OpenShift AI (RHOAI) 3.3+                      │
│  • Workbench UI  • Hardware Profiles  • Model Serving   │
├─────────────────────────────────────────────────────────┤
│  Kueue (Red Hat build) stable-v1.3                      │
│  • ClusterQueues  • LocalQueues  • Cohort borrowing     │
│  • Priority + Preemption  • Gang scheduling             │
│  • Time-based policy (CronJobs)                         │
├─────────────────────────────────────────────────────────┤
│  NVIDIA GPU Operator                                     │
│  • MIG partitioning  • Timeslicing  • DRA (OCP 4.21+)  │
│  • DCGM metrics  • Node Feature Discovery               │
│  Validated on: NVIDIA A30                               │
│  Expected to work: A100, H100, H200 (see PREREQUISITES) │
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
├── inference-cluster-queue  nominalQuota: 1 large + 1 full + 1 small
├── ds-cluster-queue         nominalQuota: 2 small,  borrowingLimit: 2
├── research-cluster-queue   nominalQuota: 1 small,  borrowingLimit: 3
├── finetune-cluster-queue   nominalQuota: 0 large,  borrowingLimit: 1
└── analytics-cluster-queue  nominalQuota: CPU only
```

---

## GPU partitioning options

Choose one mode per node. Set in `env.sh` before running setup.

| Mode | env.sh setting | Best for |
|---|---|---|
| MIG (recommended) | `MIG_STRATEGY=small (or mixed, full-combo)` | Hard memory isolation between teams |
| Timeslicing | `MIG_STRATEGY=dedicated` + configure `03-timeslicing/` | Older GPUs without MIG support |
| Full GPU | `MIG_STRATEGY=dedicated` | Large model inference, DRA demos |
