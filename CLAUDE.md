# CLAUDE.md — AI Assistant Context for openshift-gpuaas-demo

This file gives Claude full context to assist with validation and troubleshooting.
It will be removed after validation is complete.

---

## What this repo is

A full working demo of GPU-as-a-Service on OpenShift using Kueue, RHOAI, and ACM.
Nine use cases covering GPU sharing governance: quota enforcement, priority preemption,
gang scheduling, time-based policy, multi-cluster dispatch, and more.

Public repo: https://github.com/dinlaks/openshift-gpuaas-demo

---

## Current validation environment

- **Clusters**: 2× Single Node OpenShift (SNO), OCP 4.22, Kubernetes 1.35
- **GPUs**: 2× NVIDIA A30 per SNO node (128 GB RAM per node)
- **GPU strategy**: `MIG_STRATEGY=mixed`
  - GPU[0]: 4× `nvidia.com/mig-1g.6gb` (small slices)
  - GPU[1]: 1× `nvidia.com/mig-2g.12gb` + 2× `nvidia.com/mig-1g.6gb` (mixed)
- **UC2 approach**: Toggle — run `deploy-dra.sh` before UC2, `teardown-dra.sh` after
- **RHOAI**: 3.4 (`stable-3.4`)
- **Kueue**: `stable-v1.4`
- **GPU Operator channel**: auto-detected from marketplace
- **NODE_ROLES**: not used (1 Kubernetes node per SNO, MIG_STRATEGY covers it)

SNO node names — verify before NODE_ROLES:
```bash
oc get nodes -l nvidia.com/gpu.present=true
```

---

## Key design decisions

### GPU_TYPE drives everything
Set `GPU_TYPE=a30` in `env.sh` → `resolve_gpu_config()` in `lib/common.sh` auto-sets:
- `MIG_SMALL_RESOURCE=nvidia.com/mig-1g.6gb`
- `MIG_LARGE_RESOURCE=nvidia.com/mig-2g.12gb`
- `MIG_PROFILE_SMALL=all-1g.6gb`
- `MIG_PROFILE_MIXED=mixed-a30`
- `GPU_MEMORY=24gb`, `GPU_ARCH=ampere`

All YAML templates use `${MIG_SMALL_RESOURCE}` etc. and are applied via `apply_template`
(envsubst) not `apply_cr`. Never `oc apply -f` the template YAMLs directly.

### Node capability labels (not role labels)
Nodes are labelled with capability labels, not fixed role labels:
- `demo/gpu-has-small-mig=true` — node has small MIG slices
- `demo/gpu-has-large-mig=true` — node has large MIG slices
- `demo/gpu-has-full=true` — node has a full non-MIG GPU
- `demo/gpu-type=a30`, `demo/gpu-memory=24gb`, `demo/gpu-arch=ampere`

Kueue ResourceFlavors select by `demo/gpu-has-*` labels — 3 flavors cover all topologies.
Hardware profiles use the same labels in nodeSelector.

### MIG_STRATEGY and NODE_ROLES
- `MIG_STRATEGY=small|large|dedicated|mixed|full-combo` — applies to ALL GPU nodes
- `NODE_ROLES=("node-name:role" ...)` — per-node overrides for specific nodes
- Both can be used together: NODE_ROLES overrides listed nodes, rest get MIG_STRATEGY
- Scripts validate NODE_ROLES node names against the cluster and warn if not found

### Operator channels (all auto-detect or explicit)
- `RHOAI_CHANNEL=stable-3.4`
- `KUEUE_CHANNEL=stable-v1.4`
- `GPU_OPERATOR_CHANNEL=` (auto-detect from marketplace default)
- `NFD_CHANNEL=` (auto-detect from OCP version)
- `LVM_CHANNEL=` (auto-detect — only if using optional/storage/)

---

## Setup flow

```bash
# 1. Configure
cp env.sh.example env.sh
# Fill in: OCP_API_URL, OCP_USERNAME, OCP_PASSWORD, GPU_TYPE=a30, MIG_STRATEGY=mixed

# 2. Validate before touching the cluster
bash preflight-check.sh           # single cluster
bash preflight-check.sh --multi   # also validates Cluster B + ACM (for UC7)

# 3. Deploy
bash setup.sh

# 4. Verify GPU nodes labelled correctly
bash 02-gpu-setup/05-validation/validate-nodes.sh
bash 02-gpu-setup/05-validation/validate-nodes.sh --wide   # includes MIG config state
```

---

## Use case flow

| UC | Command | Notes |
|---|---|---|
| UC1 | Show RHOAI dashboard hardware profiles | No job submission needed |
| UC2 | `bash 02-gpu-setup/04-dra/deploy-dra.sh` then demo then `teardown-dra.sh` | Toggle — full GPU on GPU[1] |
| UC3 | `cd use-cases/uc3-multi-tenant && bash run-demo.sh` | |
| UC4 | `cd use-cases/uc4-queue-scheduling && bash run-demo.sh 1` then `bash run-demo.sh 2` | 2 steps |
| UC5 | `cd use-cases/uc5-priority-preemption && bash run-demo.sh 1` then `bash run-demo.sh 2` | 2 steps |
| UC6 | `cd use-cases/uc6-model-placement && bash run-demo.sh` | |
| UC7 | `cd multi-cluster/uc7-global-gpu-pool && bash run-demo.sh` | Requires multi-cluster setup |
| UC8 | `cd use-cases/uc8-gang-scheduling && bash run-demo.sh 1` then `bash run-demo.sh 2` | 2 steps |
| UC9 | `cd use-cases/uc9-time-based-policy && bash run-demo.sh weekday` then `bash run-demo.sh weekend` | |

Cleanup between UCs:
```bash
bash cleanup.sh uc3        # specific UC
bash cleanup.sh all        # all workloads
bash cleanup.sh all --hard # also removes Kueue queues and hardware profiles
```

---

## Multi-cluster setup (UC7)

```bash
# On SNO-A (hub):
bash multi-cluster/01-acm-setup/01-install-hub.sh
bash multi-cluster/01-acm-setup/03-import-cluster-b.sh
bash multi-cluster/02-multikueue/01-multikueue-setup.sh   # also applies ACM policy + observability

# Validate multi-cluster prereqs:
bash preflight-check.sh --multi
```

Files moved from private repo — current locations:
- ACM policy: `multi-cluster/01-acm-setup/08-acm-gpu-policy.yaml`
- ACM policy binding: `multi-cluster/01-acm-setup/09-acm-policy-binding.yaml`
- ACM observability: `multi-cluster/03-acm-observability/10-acm-observability.yaml`
- Grafana dashboard: `multi-cluster/03-acm-observability/grafana-dcgm-mig-dashboard.json`

---

## Common pitfalls during validation

1. **YAML templates applied directly** — never `oc apply -f 05-kueue/01-resource-flavors.yaml`
   directly. Always go through `deploy-kueue.sh` which uses `apply_template`.

2. **MIG_PROFILE not found** — if mig-manager fails, check profile name exists in
   `02-gpu-setup/02-mig/mig-parted-config.yaml`. For A30 mixed: `mixed-a30`.

3. **NODE_ROLES node name wrong** — scripts warn but fall back to MIG_STRATEGY silently.
   Verify: `oc get nodes -l nvidia.com/gpu.present=true -o custom-columns='NAME:.metadata.name'`

4. **Operator channel not found** — preflight-check.sh catches this. If GPU_OPERATOR_CHANNEL
   auto-detect fails, run: `oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'`

5. **Kueue namespace label missing** — deploy-kueue.sh labels namespaces with
   `kueue.openshift.io/managed=true`. If labels are missing, jobs won't be intercepted.

6. **Default LocalQueues not removed** — deploy-kueue.sh removes RHOAI's auto-created
   default LocalQueues. If they exist, jobs may route to the wrong queue.

7. **UC2 DRA after teardown** — after `teardown-dra.sh`, wait for GPU Operator device plugin
   DaemonSet to restart before submitting MIG jobs again.

---

## lib/common.sh key functions

- `resolve_gpu_config` — sets all MIG_* vars from GPU_TYPE; call after load_env
- `apply_template` — envsubst + oc apply; use for any YAML with ${VAR} placeholders
- `apply_cr` — plain oc apply; use for static YAMLs
- `switch_cluster a|b` — switches OCP_API_URL/credentials and logs in (multi-cluster)
- `verify_channel pkg channel` — verifies OLM channel exists; exits with available list if not
- `resolve_channel VAR pkg [ocp-version]` — uses env var if set, auto-detects otherwise
- `label_node_capabilities node role` — sets demo/gpu-has-* labels
- `get_profile_for_role role` — returns mig-parted profile name for a role
- `wait_for description check_cmd timeout` — polls until check_cmd succeeds

---

## Repo structure quick reference

```
env.sh.example     → copy to env.sh, fill in values
preflight-check.sh → validate before setup
setup.sh           → single-cluster orchestrator
cleanup.sh         → teardown by UC label

lib/common.sh      → all shared functions
01-operators/      → operator installs (deploy-operators.sh)
02-gpu-setup/      → node labels, MIG config, DRA, timeslicing, validation
03-rbac/           → users, groups, namespaces
04-hardware-profiles/ → RHOAI HardwareProfile CRs
05-kueue/          → ResourceFlavors, ClusterQueues, LocalQueues, UC9 policy
use-cases/         → ucN-*/run-demo.sh for each use case
multi-cluster/     → 01-acm-setup/ 02-multikueue/ 03-acm-observability/ uc7/
optional/storage/  → LVM + MinIO (if no default StorageClass)
optional/maas/     → Model-as-a-Service bonus
docs/              → architecture.md hardware-guide.md
```
