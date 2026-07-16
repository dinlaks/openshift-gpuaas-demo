# Multi-Cluster Add-On — MultiKueue + ACM (UC7)

This add-on extends the single-cluster setup with cross-cluster GPU scheduling via
**MultiKueue** and **Red Hat Advanced Cluster Management (ACM)**.

Users submit jobs to a single global queue. MultiKueue transparently dispatches them
to whichever cluster has capacity — the user never chooses a cluster.

## What you need

- Two OCP clusters, both with the single-cluster setup complete (`setup.sh` run on each)
- ACM hub installed on Cluster A (`01-acm-setup/`)
- Cluster B imported into ACM as a ManagedCluster
- Both clusters running Kueue (already done by `setup.sh`)

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
```

## Setup order

```bash
# 1. Install ACM hub on Cluster A
bash 01-acm-setup/01-install-hub.sh

# 2. Import Cluster B into ACM
bash 01-acm-setup/03-import-cluster-b.sh

# 3. Configure MultiKueue (generates kubeconfig secret for Cluster B)
bash 02-multikueue/01-multikueue-setup.sh

# 4. Run UC7 demo
cd uc7-global-gpu-pool && bash run-demo.sh
```

## UC7: Global GPU Pool

Submit one job to the global queue. MultiKueue dispatches it to whichever cluster
has available GPU capacity — automatically, transparently.

```bash
# Watch dispatch:
oc get workloads -n inference-team-project -w
oc get jobs -n inference-team-project      # shadow job appears on winning cluster
```
