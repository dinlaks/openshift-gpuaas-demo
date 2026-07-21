#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Deploy optional storage components.
#
# Usage:
#   bash deploy-storage.sh --lvm           # LVM Operator only (bare-metal local disk)
#   bash deploy-storage.sh --minio         # MinIO only (ACM Observability)
#   bash deploy-storage.sh --lvm --minio   # both (bare-metal + ACM Observability)
#
# Configure in env.sh before running:
#   LVM_DISK_PATH      — block device for LVM (e.g. /dev/sdb). Run: lsblk
#   LVM_STORAGE_CLASS  — StorageClass name to create (e.g. lvms-vg1)
#   LVM_CHANNEL        — OCP version channel (e.g. stable-4.22); auto-detected if unset
#   MINIO_ACCESS_KEY   — MinIO root user
#   MINIO_SECRET_KEY   — MinIO root password
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

DEPLOY_LVM=false
DEPLOY_MINIO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lvm)   DEPLOY_LVM=true ;;
    --minio) DEPLOY_MINIO=true ;;
    *) error "Unknown argument: $1. Use --lvm and/or --minio"; exit 1 ;;
  esac
  shift
done

if [[ "${DEPLOY_LVM}" == "false" && "${DEPLOY_MINIO}" == "false" ]]; then
  error "Specify at least one option: --lvm and/or --minio"
  echo "Usage: bash deploy-storage.sh --lvm --minio"
  exit 1
fi

load_env
require_oc_login

LVM_DISK_PATH="${LVM_DISK_PATH:-}"
LVM_STORAGE_CLASS="${LVM_STORAGE_CLASS:-lvms-vg1}"
LVM_CHANNEL=$(resolve_channel "LVM_CHANNEL" "lvms-operator" "ocp-version")
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minio}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minio123}"

export LVM_DISK_PATH LVM_STORAGE_CLASS LVM_CHANNEL MINIO_ACCESS_KEY MINIO_SECRET_KEY

STORAGE_VARS='${LVM_DISK_PATH}${LVM_STORAGE_CLASS}${LVM_CHANNEL}${MINIO_ACCESS_KEY}${MINIO_SECRET_KEY}'

# ── LVM Operator ──────────────────────────────────────────────────────────────
if [[ "${DEPLOY_LVM}" == "true" ]]; then
  [[ -z "${LVM_DISK_PATH}" ]] && error "LVM_DISK_PATH is not set in env.sh. Run: lsblk" && exit 1

  header "LVM Storage Operator (channel=${LVM_CHANNEL})"
  envsubst "${STORAGE_VARS}" < "${SCRIPT_DIR}/01-lvm-operator.yaml" | oc apply -f -
  wait_operator lvms-operator openshift-storage 300
  wait_for "LVMCluster CRD registered" \
    "oc get crd lvmclusters.lvm.topolvm.io &>/dev/null" 60 5

  if oc get lvmcluster gpuaas-lvmcluster -n openshift-storage &>/dev/null; then
    info "LVMCluster already exists — skipping"
  else
    info "Creating LVMCluster on disk: ${LVM_DISK_PATH}"
    envsubst "${STORAGE_VARS}" < "${SCRIPT_DIR}/02-lvm-cluster.yaml" | oc apply -f -
  fi

  wait_for "LVMCluster ready" \
    "oc get lvmcluster gpuaas-lvmcluster -n openshift-storage \
      -o jsonpath='{.status.conditions[?(@.type==\"ResourcesAvailable\")].status}' \
      2>/dev/null | grep -qi true" 300
  wait_for "StorageClass ${LVM_STORAGE_CLASS} available" \
    "oc get storageclass ${LVM_STORAGE_CLASS} &>/dev/null" 120

  success "LVM StorageClass '${LVM_STORAGE_CLASS}' ready"
fi

# ── MinIO ─────────────────────────────────────────────────────────────────────
if [[ "${DEPLOY_MINIO}" == "true" ]]; then
  header "MinIO (S3-compatible storage for ACM Observability)"

  if oc get deployment minio -n minio &>/dev/null; then
    info "MinIO already deployed — skipping"
  else
    envsubst "${STORAGE_VARS}" < "${SCRIPT_DIR}/03-minio.yaml" | oc apply -f -
  fi

  wait_for "MinIO pod running" \
    "oc get pods -n minio -l app=minio --field-selector=status.phase=Running \
      --no-headers 2>/dev/null | grep -q ." 180

  MINIO_ROUTE=$(oc get svc minio -n minio -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  success "MinIO deployed — S3 endpoint: http://${MINIO_ROUTE}:9000"
  info "Set in env.sh:  MINIO_ENDPOINT=http://minio.minio.svc.cluster.local:9000"
fi
