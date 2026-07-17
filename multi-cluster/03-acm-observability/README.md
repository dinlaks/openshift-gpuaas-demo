# ACM Observability — Unified GPU Metrics Across Clusters

ACM Observability aggregates Prometheus metrics from all managed clusters into
a single Thanos instance on the hub. This gives you one Grafana dashboard showing
GPU utilization, memory, temperature, and power across every cluster simultaneously.

## What you get

- Single Grafana dashboard on Cluster A showing DCGM GPU metrics from all clusters
- Per-tenant GPU slice visibility across the fleet
- Real-time metrics: utilization, memory used, temperature, power draw
- Supports both MIG and non-MIG GPUs

## Prerequisites

- ACM Hub installed and Cluster B imported (`01-acm-setup/`)
- Object storage for Thanos — use MinIO (`optional/storage/deploy-storage.sh --minio`)
  or any S3-compatible endpoint
- `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` set in `env.sh`

## Deploy

```bash
# Apply on Cluster A (Hub) only
oc apply -f multi-cluster/03-acm-observability/10-acm-observability.yaml
```

Wait for the observability stack to come up (~5 min):

```bash
oc get pods -n open-cluster-management-observability -w
```

## Import the Grafana dashboard

Once observability is running, the ACM Hub exposes a Grafana instance.

1. Get the Grafana URL:
   ```bash
   oc get route grafana -n open-cluster-management-observability \
     -o jsonpath='{.spec.host}'
   ```

2. Log in to Grafana (uses OpenShift SSO)

3. Import the dashboard:
   - Go to **Dashboards → Import**
   - Upload `grafana-dcgm-mig-dashboard.json` from this folder
   - Set the Prometheus datasource UID to `000000001` (ACM's default Thanos datasource)
   - Click **Import**

The dashboard shows GPU metrics labeled by cluster, namespace, and tenant — giving
full visibility into how GPU resources are being used across your fleet.

## What the dashboard shows

| Panel | Metric |
|---|---|
| GPU Utilization | `DCGM_FI_PROF_GR_ENGINE_ACTIVE` |
| Memory Used | `DCGM_FI_DEV_FB_USED` |
| Memory Utilization | `DCGM_FI_DEV_MEM_COPY_UTIL` |
| Temperature | `DCGM_FI_DEV_GPU_TEMP` |
| Power Draw | `DCGM_FI_DEV_POWER_USAGE` |

MIG slice metrics are broken out by `GPU_I_PROFILE` label so you can see
utilization per slice tier (small vs large MIG).
