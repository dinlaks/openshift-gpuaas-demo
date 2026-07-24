# Multi-Cluster Add-On — ACM + MultiKueue + Observability

This add-on extends the single-cluster setup with three capabilities:

| Folder | What it does |
|---|---|
| `01-acm-setup/` | Install ACM Hub, import spoke cluster, enforce GPU policy across clusters |
| `02-multikueue/` | Cross-cluster GPU job dispatch — users submit once, platform picks the cluster |
| `03-acm-observability/` | Unified GPU metrics from all clusters in one Grafana dashboard |
| `uc7-global-gpu-pool/` | UC7 demo — global GPU pool via MultiKueue |

## Cluster roles

| Role | Description |
|---|---|
| **Cluster A (Hub)** | Primary cluster. Runs ACM, MultiKueue control plane, and Grafana. Same cluster as `OCP_API_URL` in `env.sh`. |
| **Spoke Cluster** | Second cluster. Receives jobs dispatched by MultiKueue. Identified by `SPOKE_CLUSTER_TARGET` in `env.sh`. |

## What you need

- **Two OCP clusters** — any topology (SNO, 3-node compact, or full multi-node)
- **A default StorageClass on each cluster** — required for RHOAI PVCs:
  - Cloud-hosted or ODF clusters: already have one — no action needed
  - Bare-metal SNO: deploy LVM before running `setup.sh` (see `optional/storage/README.md`)
  - 3-node compact or multi-node: deploy ODF before running `setup.sh`
  - Verify: `oc get storageclass` — a `(default)` entry means you're good
- **Single-cluster setup complete on both clusters** (run from repo root):
  - Cluster A: `bash optional/storage/deploy-storage.sh --lvm` then `bash setup.sh`
  - Spoke cluster: `bash optional/storage/deploy-storage.sh --lvm --cluster <name>` then `bash setup.sh --cluster <name>`
- Both clusters running Kueue (handled by `setup.sh`)
- MinIO for ACM Observability (run from repo root): `bash optional/storage/deploy-storage.sh --minio`

## Additional env.sh variables

Uncomment and fill in the multi-cluster section in `env.sh`:

```bash
# Cluster A — hub (same cluster as OCP_API_URL / OCP_USERNAME / OCP_PASSWORD)
CLUSTER_A_API_URL=https://api.your-hub-cluster.example.com:6443
CLUSTER_A_USERNAME=kubeadmin
CLUSTER_A_PASSWORD=<password>
# CLUSTER_A_KUBECONFIG=<path>   # [optional] alternative to username/password

# Spoke cluster — identified by SPOKE_CLUSTER_TARGET
# The name must match the CLUSTER_<NAME>_* block below
# Use your OCP cluster's short identity (e.g. from: oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
SPOKE_CLUSTER_TARGET=<cluster-name>   # e.g. ai160

CLUSTER_<NAME>_API_URL=https://api.your-spoke-cluster.example.com:6443
CLUSTER_<NAME>_USERNAME=kubeadmin
CLUSTER_<NAME>_PASSWORD=<password>
# CLUSTER_<NAME>_KUBECONFIG=<path>   # [optional] alternative to username/password
# Note: ACM ManagedCluster name = SPOKE_CLUSTER_TARGET — clear and user-controlled

MINIO_ENDPOINT=http://minio.minio.svc.cluster.local:9000
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
```

> To add more clusters to the GPU pool later, just add another `CLUSTER_<NAME>_*` block and run the setup steps for that cluster.

## Setup order

> All commands run from the **repo root** (`openshift-gpuaas-demo/`).

```bash
# 1. Install ACM Hub on Cluster A
bash multi-cluster/01-acm-setup/01-install-hub.sh

# 2. Import spoke cluster into ACM
bash multi-cluster/01-acm-setup/03-import-spoke-cluster.sh

# 3. Deploy MinIO on Cluster A — required for ACM Observability (Thanos metrics storage)
bash optional/storage/deploy-storage.sh --minio

# 4. Configure MultiKueue, GPU policy, ACM Observability, and Grafana dashboard
bash multi-cluster/02-multikueue/01-multikueue-setup.sh

# 5. Run UC7 demo
bash multi-cluster/uc7-global-gpu-pool/run-demo.sh
```

## UC7: Global GPU Pool

Submit one job to the global queue. MultiKueue dispatches it to whichever cluster
has available GPU capacity — automatically, transparently.

```bash
oc get workloads -n inference-team-project -w
oc get jobs -n inference-team-project      # shadow job appears on winning cluster
```
