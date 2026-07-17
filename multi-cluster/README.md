# Multi-Cluster Add-On — ACM + MultiKueue + Observability

This add-on extends the single-cluster setup with three capabilities:

| Folder | What it does |
|---|---|
| `01-acm-setup/` | Install ACM Hub, import Cluster B, enforce GPU policy across clusters |
| `02-multikueue/` | Cross-cluster GPU job dispatch — users submit once, platform picks the cluster |
| `03-acm-observability/` | Unified GPU metrics from all clusters in one Grafana dashboard |
| `uc7-global-gpu-pool/` | UC7 demo — global GPU pool via MultiKueue |

## What you need

- Two OCP clusters, both with the single-cluster setup complete (`setup.sh` run on each)
- ACM hub installed on Cluster A (`01-acm-setup/`)
- Cluster B imported into ACM as a ManagedCluster
- Both clusters running Kueue (already done by `setup.sh`)
- MinIO or S3-compatible storage for ACM Observability (`optional/storage/deploy-storage.sh --minio`)

## Additional env.sh variables

Uncomment the multi-cluster section in `env.sh`:

```bash
CLUSTER_A_API_URL=https://api.cluster-a.example.com:6443
CLUSTER_A_USERNAME=gpuaas-admin
CLUSTER_A_PASSWORD=<password>
CLUSTER_A_NAME=cluster-a
CLUSTER_A_KUBECONFIG=<path>

CLUSTER_B_API_URL=https://api.cluster-b.example.com:6443
CLUSTER_B_USERNAME=gpuaas-admin
CLUSTER_B_PASSWORD=<password>
CLUSTER_B_NAME=cluster-b
CLUSTER_B_KUBECONFIG=<path>

MINIO_ENDPOINT=http://minio.minio.svc.cluster.local:9000
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
```

## Setup order

```bash
# 1. Install ACM Hub on Cluster A
bash 01-acm-setup/01-install-hub.sh

# 2. Import Cluster B + apply GPU policy across both clusters
bash 01-acm-setup/03-import-cluster-b.sh
oc apply -f 01-acm-setup/08-acm-gpu-policy.yaml
oc apply -f 01-acm-setup/09-acm-policy-binding.yaml

# 3. Configure MultiKueue (generates kubeconfig secret for Cluster B)
bash 02-multikueue/01-multikueue-setup.sh

# 4. Enable ACM Observability (unified GPU metrics)
oc apply -f 03-acm-observability/10-acm-observability.yaml
# Then import grafana-dcgm-mig-dashboard.json — see 03-acm-observability/README.md

# 5. Run UC7 demo
cd uc7-global-gpu-pool && bash run-demo.sh
```

## UC7: Global GPU Pool

Submit one job to the global queue. MultiKueue dispatches it to whichever cluster
has available GPU capacity — automatically, transparently.

```bash
oc get workloads -n inference-team-project -w
oc get jobs -n inference-team-project      # shadow job appears on winning cluster
```
