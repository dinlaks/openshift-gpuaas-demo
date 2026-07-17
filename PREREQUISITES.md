# Prerequisites

## OpenShift

| Component | Minimum version | Notes |
|---|---|---|
| OpenShift Container Platform | 4.17+ | 4.21 recommended (DRA GA, no feature gate needed) |
| Kubernetes | 1.30+ | |

## NVIDIA GPUs

> **Testing note:** This repo was fully validated end-to-end on **NVIDIA A30 GPUs** only.
> All other GPU types listed below should work based on standard NVIDIA GPU Operator and
> Kueue behavior, but have not been independently verified. If you test on a different
> GPU type, contributions and feedback are welcome.

| GPU | Memory | MIG support | GPU_TYPE value | Validated |
|---|---|---|---|---|
| A30 | 24 GB | Yes | `a30` | ✅ Full end-to-end |
| A100 PCIe/SXM4 | 40 GB | Yes | `a100-40gb` | Expected to work |
| A100 PCIe/SXM4 | 80 GB | Yes | `a100-80gb` | Expected to work |
| H100 SXM5/PCIe | 80 GB | Yes | `h100-80gb` | Expected to work |
| H100 NVL | 94 GB | Yes | `h100-nvl` | Expected to work |
| H200 SXM5 | 141 GB | Yes | `h200` | Expected to work |
| Other | any | varies | `custom` | Manual config required |

> **Note:** MIG is optional. Set `MIG_ENABLED=false` in `env.sh` to use timeslicing
> or full-GPU mode instead. See `02-gpu-setup/03-timeslicing/` for timeslicing setup.

## Operators (installed by `01-operators/deploy-operators.sh`)

| Operator | Channel | Namespace |
|---|---|---|
| Node Feature Discovery | stable | openshift-nfd |
| NVIDIA GPU Operator | v24.x or later | nvidia-gpu-operator |
| Red Hat build of Kueue | stable-v1.3 | openshift-kueue-operator |
| Red Hat OpenShift AI | stable-3.3+ (3.3 recommended) | redhat-ods-operator |
| Red Hat cert-manager | stable-v1 | cert-manager-operator |
| OpenShift Service Mesh 3 | stable | openshift-operators |
| OpenShift Serverless | stable | openshift-serverless |

> **Important:** RHOAI's built-in Kueue must be set to `Unmanaged` (already configured
> in `wave-1-rhoai-datasciencecluster.yaml`). Do not change it to `Managed` — it
> conflicts with the standalone Kueue operator.

## CLI tools

- `oc` — OpenShift CLI (matches your cluster version)
- `kubectl` — optional (oc covers all commands used here)
- `htpasswd` — for creating demo users (`dnf install httpd-tools` or `brew install httpd`)
- `helm` — only needed for UC2 DRA (`brew install helm` or `dnf install helm`)

## Multi-cluster add-on (optional, for UC7 only)

- A second OCP cluster with the same single-cluster setup applied
- Red Hat Advanced Cluster Management (ACM) 2.10+ on the hub cluster
- Network connectivity between clusters (API server reachable)

## Storage

RHOAI workbenches, pipelines, and model storage require PVCs. The setup scripts
assume a default StorageClass already exists on your cluster.

**Check first:**
```bash
oc get storageclass
```

If a `(default)` StorageClass is listed — no action needed, proceed with `setup.sh`.

If no default StorageClass exists (common on bare-metal OCP installs), use the
optional storage setup before running `setup.sh`:

| Component | When needed | Script |
|---|---|---|
| LVM Operator | Bare-metal OCP with local disks, no existing StorageClass | `bash optional/storage/deploy-storage.sh --lvm` |
| MinIO | ACM Observability for multi-cluster add-on (UC7) | `bash optional/storage/deploy-storage.sh --minio` |

Configure `LVM_DISK_PATH`, `LVM_STORAGE_CLASS`, and `LVM_CHANNEL` in `env.sh`
before deploying LVM. See `optional/storage/README.md` for full guidance.

> **Cloud-hosted OCP users:** AWS, Azure, and GCP clusters have a default StorageClass
> pre-configured. Skip this section entirely.

## Cluster sizing

Single-cluster minimum for running all use cases:

| Resource | Minimum |
|---|---|
| Worker nodes | 1 GPU node + 1 CPU-only node |
| GPU node RAM | 64 GB |
| GPU node vCPUs | 16 |
| Storage | 200 GB for RHOAI model storage |

The demo was developed on bare-metal servers (no cloud required). It runs on any
OCP installation — on-prem, cloud, or single-node.
