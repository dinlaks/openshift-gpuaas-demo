# Multi-Cluster Add-On — ACM + MultiKueue + Observability

This add-on extends the single-cluster setup with three capabilities:

| Folder | What it does |
|---|---|
| `01-acm-setup/` | Install ACM Hub, import Cluster B, enforce GPU policy across clusters |
| `02-multikueue/` | Cross-cluster GPU job dispatch — users submit once, platform picks the cluster |
| `03-acm-observability/` | Unified GPU metrics from all clusters in one Grafana dashboard |
| `uc7-global-gpu-pool/` | UC7 demo — global GPU pool via MultiKueue |

## What you need

- **Two OCP clusters** — any topology (SNO, 3-node compact, or full multi-node)
- **A default StorageClass on each cluster** — required for RHOAI PVCs:
  - Cloud-hosted or ODF clusters: already have one — no action needed
  - Bare-metal SNO: `bash optional/storage/deploy-storage.sh --lvm` (see `optional/storage/README.md`)
  - 3-node compact or multi-node without storage: deploy ODF before running `setup.sh`
  - Verify: `oc get storageclass` — a `(default)` entry means you're good
- **Single-cluster setup complete on both clusters** (run from repo root):
  - Cluster A: `bash setup.sh`
  - Cluster B: `bash setup.sh --cluster b`
- Both clusters running Kueue (handled by `setup.sh`)
- MinIO for ACM Observability (run from repo root): `bash optional/storage/deploy-storage.sh --minio`

## Cluster roles

| Role | Description |
|---|---|
| **Cluster A (Hub)** | Primary cluster. Runs ACM, MultiKueue control plane, and Grafana. This is the same cluster you point `OCP_API_URL` at in `env.sh`. |
| **Cluster B (Spoke)** | Second cluster. Receives jobs dispatched by MultiKueue from the hub. |

## Additional env.sh variables

Uncomment and fill in the multi-cluster section in `env.sh`:

```bash
# Cluster A — hub (same cluster as OCP_API_URL / OCP_USERNAME / OCP_PASSWORD)
CLUSTER_A_API_URL=https://api.your-hub-cluster.example.com:6443
CLUSTER_A_USERNAME=kubeadmin
CLUSTER_A_PASSWORD=<password>
# CLUSTER_A_KUBECONFIG=<path>   # [optional] alternative to username/password

# Cluster B — spoke (second cluster for UC7)
CLUSTER_B_API_URL=https://api.your-spoke-cluster.example.com:6443
SPOKE_CLUSTER_USERNAME=kubeadmin
SPOKE_CLUSTER_PASSWORD=<password>
# SPOKE_CLUSTER_KUBECONFIG=<path>   # [optional] alternative to username/password
# CLUSTER_B_NAME is auto-detected from Cluster B's OCP infrastructure name — no manual config needed

MINIO_ENDPOINT=http://minio.minio.svc.cluster.local:9000
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
```

## Setup order

> All commands run from the **repo root** (`openshift-gpuaas-demo/`).

```bash
# 1. Install ACM Hub on Cluster A
bash multi-cluster/01-acm-setup/01-install-hub.sh

# 2. Import Cluster B (also applies GPU policy across both clusters)
bash multi-cluster/01-acm-setup/03-import-cluster-b.sh

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
