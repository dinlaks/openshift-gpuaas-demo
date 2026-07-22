# Optional: Storage Setup

Storage is **not required** if your OCP cluster already has a default StorageClass
(most cloud-hosted and pre-configured on-prem clusters do).

If you are starting from a bare-metal OCP install with no StorageClass, use this
folder to set one up before running `setup.sh`.

---

## When do you need this?

| Scenario | Storage needed |
|---|---|
| Cloud-hosted OCP (AWS, Azure, GCP) | Not needed — default StorageClass exists |
| OCP with ODF (OpenShift Data Foundation) | Not needed — StorageClass exists |
| Bare-metal SNO (Single Node OpenShift) | **Yes** — use LVM Operator below |
| Bare-metal 3-node compact or full multi-node | **Yes** — ODF recommended; LVM works but PVs are node-local (no replication) |
| Multi-cluster add-on + ACM Observability | **Yes** — MinIO needed for Thanos metrics |

Check if you already have a default StorageClass:
```bash
oc get storageclass
```

If any row shows `(default)` — you can skip this folder entirely.

---

## Option A: LVM Operator (best suited for SNO)

Provides a `StorageClass` backed by a local disk on the node.
Best suited for **Single Node OpenShift (SNO)** — simple, no external storage required.
For 3-node compact or full multi-node clusters, use **ODF** (OpenShift Data Foundation)
instead, which provides replicated distributed storage across nodes.

**Configure in `env.sh`:**
```bash
LVM_DISK_PATH=/dev/sdX        # your unused block device — run lsblk on the node to find yours
LVM_STORAGE_CLASS=lvms-vg1    # name for the StorageClass created by LVM
LVM_CHANNEL=                  # auto-detected from your OCP version (e.g. stable-4.22 for OCP 4.22)
```

> **Important:** `LVM_DISK_PATH` must point to an **unused, unformatted** block device.
> The LVM Operator will wipe and claim it. Run `lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT`
> on your GPU node to identify available disks before setting this value.

**Identify your disk:**
```bash
oc debug node/<node-name> -- chroot /host lsblk -d -o NAME,SIZE,TYPE
```

**If LVM fails with "device is partitioned"** — the disk has stale partition or LVM
signatures from a previous install. Wipe it first:
```bash
oc debug node/<node-name> -- chroot /host bash -c "
  wipefs -a ${LVM_DISK_PATH} &&
  dd if=/dev/zero of=${LVM_DISK_PATH} bs=1M count=10
"
```
Then delete any failed LVMCluster and redeploy:
```bash
oc delete lvmcluster gpuaas-lvmcluster -n openshift-storage
bash optional/storage/deploy-storage.sh --lvm
```

**Deploy:**
```bash
bash optional/storage/deploy-storage.sh --lvm
```

---

## Option B: MinIO (S3-compatible object store)

Required only for the **multi-cluster add-on** (ACM Observability / Thanos metrics).
Not needed for single-cluster setup.

MinIO runs in its own namespace and stores metrics data on a PVC.

**Configure in `env.sh`:**
```bash
MINIO_ACCESS_KEY=minio              # change for any shared environment
MINIO_SECRET_KEY=minio123           # change for any shared environment
LVM_STORAGE_CLASS=lvms-vg1         # StorageClass for MinIO's PVC (use your default SC)
```

**Deploy:**
```bash
bash optional/storage/deploy-storage.sh --minio
```

---

## Deploy both (bare-metal + ACM Observability)

```bash
bash optional/storage/deploy-storage.sh --lvm --minio
```

LVM must be ready before MinIO — the script handles the ordering automatically.
