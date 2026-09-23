# UC10: Self-Service GPU Booking Portal

> **Demo Recording:** [▶ Watch on YouTube](https://youtu.be/NPcbaGa6oFY) — narrated live demo on a real cluster, no login required.

A calendar-based GPU reservation UI deployed as an OpenShift Console Plugin. Data scientists book GPU time slots via a web interface — no YAML, no tickets, no admin intervention. The platform auto-creates Kueue resources and enforces reservations automatically.

## What It Shows

- **Self-service calendar booking** — users pick date range, GPU type, and quantity
- **Live availability** — real-time view of which GPU slots are free, consumed, or reserved
- **Auto-provisioned Kueue resources** — ClusterQueue + HardwareProfile created automatically per booking
- **Time-bounded enforcement** — reservation expires → HoldAndDrain → ClusterQueue deleted automatically
- **GPU auto-discovery** — plugin detects all GPU types and MIG slices from node labels every 5 minutes

## Architecture

```
OCP Console Plugin (React/PatternFly)
    ↓ REST API
Go Backend (:9443 TLS)
    ↓ Kubernetes API
Kueue ClusterQueue (per booking, labeled rhai-tmm.dev/until=<expiry>)
    ↓ cohort: gpuaas-cohort
Existing ClusterQueues (inference, ds, research, finetune, analytics)
```

The plugin **never modifies existing ClusterQueues** — it creates isolated per-booking queues in the same cohort. Existing UC1-UC9 workloads are unaffected.

## About the Demo Namespaces

UC10 uses dedicated `user-*` namespaces created specifically for this demonstration:

| Namespace | User | GPU Access |
|---|---|---|
| `user-alice` | alice | MIG 1g.6gb, Full GPU |
| `user-bob` | bob | MIG 1g.6gb |
| `user-charlie` | charlie | MIG 1g.6gb |
| `user-diana` | diana | MIG 1g.6gb |
| `user-gpuaas-admin` | gpuaas-admin | All GPU types |

These namespaces are **separate from UC1-UC9 namespaces** (`inference-team-project`, `research-team-project`, etc.). The booking plugin maps OCP username → `user-<username>` namespace. When a user makes a booking, the plugin creates a `LocalQueue/reserved` and `HardwareProfile` in their `user-<username>` namespace automatically.

> **Why separate namespaces?** UC1-UC9 demonstrate team-level GPU governance. UC10 demonstrates user-level self-service booking. The `user-*` namespaces keep the booking demonstration isolated and clean.

## Prerequisites

- OCP 4.17+ with Kueue installed
- RHOAI 3.5+ (for HardwareProfile integration)
- `helm` CLI installed
- GPU nodes with NVIDIA drivers and DCGM metrics

## Deploy

```bash
# From repo root — auto-resolves GPU type, StorageClass, and GPU counts from env.sh
bash use-cases/uc10-gpu-booking/deploy.sh
```

The script automatically:
1. Reads `GPU_TYPE` from `env.sh` → resolves MIG resource names
2. Detects the default StorageClass from the cluster
3. Reads GPU counts from node capacity labels
4. Generates `values.yaml` and runs `helm install`

## Access

After deployment, open the OCP Console:

```
https://console-openshift-console.apps.<cluster-domain>
```

Navigate to **"GPU Bookings"** in the left sidebar (added by the plugin).

## How Reservations Work

1. User selects date range, GPU type, and quantity → clicks **Book**
2. Plugin creates a Kueue `ClusterQueue` with `nominalQuota` in `gpuaas-cohort`
3. Plugin creates a `LocalQueue/reserved` and `HardwareProfile` in the user's namespace → appears in RHOAI workbench dropdown
4. User submits workloads to `LocalQueue/reserved` — admitted immediately on the reserved slot
5. At booking cancel/expiry: plugin sets `HoldAndDrain` → graceful pod eviction → ClusterQueue, LocalQueue, and HardwareProfile all deleted

> **Namespace label requirement:** Each `user-*` namespace must have the label `rhai-tmm.dev/owner=<username>` for the portal's kueue sync to correctly match consumed workloads to reservations. This is set automatically by `deploy.sh`.

## Demo Flows

### Flow 1 — Happy Path (~5 min)
Alice books a MIG 1g.6gb slice, submits a batch inference job, it admits immediately on her reserved slot.

```bash
# After alice creates booking in portal:
bash use-cases/uc10-gpu-booking/run-demo.sh 1
```

Key things to show:
- OCP Console → GPU Bookings: live availability calendar
- Log in as alice → Reserve a MIG 1g.6gb slot
- OCP Console Search → `LocalQueue` and `HardwareProfile` auto-created in user-alice
- RHOAI Dashboard → user-alice → Create Workbench → `reserved-mig-6gb` in Hardware Profile dropdown
- `run-demo.sh 1` → OCP Console Search → Workload → `Admitted: True`

### Flow 2 — Reservation Cancellation (~2 min)
Alice cancels her booking in the portal — plugin evicts her running job via HoldAndDrain and cleans up all resources.

Key things to show:
- GPU Bookings portal → Cancel alice's booking
- OCP Console → Pods → user-alice → pod goes Terminated
- OCP Console Search → LocalQueue → gone (full cleanup)

### Flow 3 — Booking Management: Cancel & Release (~4 min)
Cluster is fully booked. Bob has a valid reservation but his job is waiting (pod Pending). Charlie cancels his booking — the slot releases and Bob's job auto-admits within seconds.

```bash
# Setup (run in order):
bash use-cases/uc10-gpu-booking/run-demo.sh cleanup
# 1. Log in as charlie → portal → create booking
bash use-cases/uc10-gpu-booking/run-demo.sh 3a
bash use-cases/uc10-gpu-booking/run-demo.sh 3-fill   # fills remaining 3 MIG slots
# 2. Log in as bob → portal → override a consumed slot → create booking
bash use-cases/uc10-gpu-booking/run-demo.sh 3b       # bob's pod goes Pending
# 3. Log in as gpuaas-admin → verify portal shows 4/4 slots full

# During demo: Log in as charlie → cancel booking → watch bob's pod go Running
```

Key things to show:
- GPU Bookings portal (as gpuaas-admin): all 4 MIG slots occupied
- OCP Console Search → Workload → user-bob: `Admitted: True`, pod Pending
- Log in as charlie → cancel booking in portal
- OCP Console → Pods → user-bob: Pending → Running (~30 seconds)

## Teardown

```bash
helm uninstall gpu-booking-plugin -n gpu-booking-app-plugin
oc delete namespace gpu-booking-app-plugin
```

## Source

Plugin source: https://github.com/rhai-code/gpu-booking-app-plugin  
Image: `quay.io/eformat/gpu-booking-plugin:latest`
