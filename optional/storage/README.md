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
| Bare-metal OCP with local disks only | **Yes** — use LVM Operator below |
| Multi-cluster add-on + ACM Observability | **Yes** — MinIO needed for Thanos metrics |

Check if you already have a default StorageClass:
```bash
oc get storageclass
```

If any row shows `(default)` — you can skip this folder entirely.

---

## Option A: LVM Operator (bare-metal local disk storage)

Provides a `StorageClass` backed by local NVMe/SSD disks on each node.
Used by RHOAI workbench PVCs, MinIO, and any stateful workloads.

**Configure in `env.sh`:**
```bash
LVM_DISK_PATH=/dev/sdb        # block device to use — run: lsblk to find yours
LVM_STORAGE_CLASS=lvms-vg1    # name for the StorageClass created by LVM
LVM_CHANNEL=stable-4.21       # match your OCP version: stable-4.17, stable-4.18, etc.
```

> **Important:** `LVM_DISK_PATH` must point to an **unused, unformatted** block device.
> The LVM Operator will wipe and claim it. Run `lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT`
> on your GPU node to identify available disks before setting this value.

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
