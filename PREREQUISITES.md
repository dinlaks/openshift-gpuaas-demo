# Prerequisites

## OpenShift

| Component | Minimum version | Recommended | Notes |
|---|---|---|---|
| OpenShift Container Platform | 4.17+ | **4.22** | EUS release, K8s 1.35, DRA GA |
| Kubernetes | 1.30+ | 1.35 | Bundled with OCP 4.22 |

> OCP 4.22 is an **EUS (Extended Update Support)** release — preferred for stability.
> DRA (UC2) requires OCP 4.21+. All other use cases work on 4.17+.

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

> **Note:** MIG is optional. Set `MIG_STRATEGY=dedicated` in `env.sh` to use full GPU or timeslicing
> or full-GPU mode instead. See `02-gpu-setup/03-timeslicing/` for timeslicing setup.

## Operators (installed by `01-operators/deploy-operators.sh`)

### Step 1 — Verify channels for your OCP + RHOAI version

The table below is validated for **OCP 4.22 + RHOAI 3.4 (July 2026)**. If you are on a
different OCP version or a newer RHOAI release, verify available channels on your
cluster **before** filling in `env.sh` — channels change with every OCP minor release.

**Check all operator channels at once:**

```bash
for pkg in rhods-operator kueue-operator gpu-operator-certified nfd \
           openshift-cert-manager-operator servicemeshoperator3 \
           serverless-operator web-terminal lvms-operator; do
  echo -n "${pkg}: "
  oc get packagemanifest "${pkg}" -n openshift-marketplace \
    -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "not found"
done
```

### Step 2 — Channel reference by OCP version

| Operator | Package name | OCP 4.21 | OCP 4.22 ✅ | Notes |
|---|---|---|---|---|
| Red Hat OpenShift AI | `rhods-operator` | `stable-3.3` | `stable-3.4` | Set `RHOAI_CHANNEL` |
| Red Hat build of Kueue | `kueue-operator` | `stable-v1.3` | `stable-v1.4` | Set `KUEUE_CHANNEL` |
| NVIDIA GPU Operator | `gpu-operator-certified` | `v25.x` | `v26.x` | **Auto-detect** — changes every release |
| Node Feature Discovery | `nfd` | `4.21` | `4.22` | **Auto-detect** — OCP version-specific |
| Red Hat cert-manager | `openshift-cert-manager-operator` | `stable-v1` | `stable-v1` | Fixed — no change needed |
| OpenShift Service Mesh 3 | `servicemeshoperator3` | `stable` | `stable` | Fixed — no change needed |
| OpenShift Serverless | `serverless-operator` | `stable` | `stable` | Fixed — no change needed |
| Web Terminal | `web-terminal` | `stable` | `stable` | Fixed — no change needed |
| LVM Operator *(optional)* | `lvms-operator` | `stable-4.21` | `stable-4.22` | **Auto-detect** — OCP version-specific |
| ACM Hub *(multi-cluster)* | `advanced-cluster-management` | `release-2.14` | `release-2.16` or `release-2.17` | Set `ACM_CHANNEL` |

**Auto-detect** channels (GPU Operator, NFD, LVM) are resolved at install time when left
blank in `env.sh`. Override by setting the variable explicitly if auto-detection fails.

### Step 3 — Set in env.sh and validate

After verifying, update `env.sh` with the channels for your OCP + RHOAI version, then:

```bash
bash preflight-check.sh   # validates all channels exist before any installation
```

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
