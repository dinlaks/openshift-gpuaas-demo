#!/usr/bin/env bash
# UC10: GPU Booking Plugin — deploy script
# Sources env.sh, auto-resolves GPU config and StorageClass, generates values.yaml, runs helm install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${REPO_ROOT}/lib/common.sh"
load_env
resolve_gpu_config
require_oc_login

header "UC10: GPU Booking Plugin — Deploy"

# ── Auto-detect StorageClass ──────────────────────────────────────────────────
info "Detecting default StorageClass..."
DEFAULT_STORAGECLASS=$(oc get storageclass -o json | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
for sc in d['items']:
    ann = sc.get('metadata',{}).get('annotations',{})
    if ann.get('storageclass.kubernetes.io/is-default-class') == 'true' or \
       ann.get('storageclass.beta.kubernetes.io/is-default-class') == 'true':
        print(sc['metadata']['name'])
        break
" 2>/dev/null || echo "")

if [[ -z "${DEFAULT_STORAGECLASS}" ]]; then
  # Fall back to first available
  DEFAULT_STORAGECLASS=$(oc get storageclass --no-headers 2>/dev/null | head -1 | awk '{print $1}')
fi

if [[ -z "${DEFAULT_STORAGECLASS}" ]]; then
  error "No StorageClass found. Deploy storage first: bash optional/storage/deploy-storage.sh --lvm"
  exit 1
fi
success "StorageClass: ${DEFAULT_STORAGECLASS}"

# ── Auto-detect GPU counts from node labels ───────────────────────────────────
info "Detecting GPU counts from node labels..."
GPU_FULL_COUNT=$(oc get node -o json | python3 -c "
import sys,json
d=json.load(sys.stdin)
total=0
for n in d['items']:
    lbs=n.get('status',{}).get('capacity',{})
    total+=int(lbs.get('nvidia.com/gpu','0'))
print(total)
" 2>/dev/null || echo "2")

MIG_SMALL_COUNT=$(oc get node -o json | python3 -c "
import sys,json,os
d=json.load(sys.stdin)
key=os.environ.get('MIG_SMALL_RESOURCE','nvidia.com/mig-1g.6gb')
total=0
for n in d['items']:
    lbs=n.get('status',{}).get('capacity',{})
    total+=int(lbs.get(key,'0'))
print(total)
" 2>/dev/null || echo "6") MIG_SMALL_RESOURCE="${MIG_SMALL_RESOURCE}"

MIG_LARGE_COUNT=$(oc get node -o json | python3 -c "
import sys,json,os
d=json.load(sys.stdin)
key=os.environ.get('MIG_LARGE_RESOURCE','nvidia.com/mig-2g.12gb')
total=0
for n in d['items']:
    lbs=n.get('status',{}).get('capacity',{})
    total+=int(lbs.get(key,'0'))
print(total)
" 2>/dev/null || echo "2") MIG_LARGE_RESOURCE="${MIG_LARGE_RESOURCE}"

GPU_ARCH_UPPER=$(echo "${GPU_ARCH:-ampere}" | tr '[:lower:]' '[:upper:]')

info "GPU counts detected: full=${GPU_FULL_COUNT}, small-mig=${MIG_SMALL_COUNT}, large-mig=${MIG_LARGE_COUNT}"

# ── Generate values.yaml from template ───────────────────────────────────────
info "Generating values.yaml from template..."
export DEFAULT_STORAGECLASS GPU_FULL_COUNT MIG_SMALL_COUNT MIG_LARGE_COUNT GPU_ARCH_UPPER
export MIG_SMALL_RESOURCE MIG_LARGE_RESOURCE FULL_GPU_RESOURCE GPU_MEMORY

envsubst < "${SCRIPT_DIR}/values.yaml.template" > "${SCRIPT_DIR}/values.yaml"
success "Generated: use-cases/uc10-gpu-booking/values.yaml"

# ── Deploy via Helm ───────────────────────────────────────────────────────────
NS="gpu-booking-app-plugin"

if helm status gpu-booking-plugin -n "${NS}" &>/dev/null 2>&1; then
  info "Upgrading existing installation..."
  helm upgrade gpu-booking-plugin "${SCRIPT_DIR}/chart" \
    -n "${NS}" \
    -f "${SCRIPT_DIR}/values.yaml"
  success "Upgraded: gpu-booking-plugin"
else
  info "Installing GPU Booking Plugin..."
  helm install gpu-booking-plugin "${SCRIPT_DIR}/chart" \
    -n "${NS}" --create-namespace \
    -f "${SCRIPT_DIR}/values.yaml"
  success "Installed: gpu-booking-plugin"
fi

# ── Wait for rollout ──────────────────────────────────────────────────────────
info "Waiting for plugin pod to be ready..."
oc rollout status deployment/gpu-booking-plugin -n "${NS}" --timeout=120s

# ── Create user namespaces (plugin maps <username> → user-<username>) ─────────
info "Creating user namespaces for GPU booking personas..."
# Plugin requires namespace user-<username> to exist before it can create
# LocalQueue and HardwareProfile resources for each booking user.
# eve is excluded — analytics-only user, no GPU access
for user in gpuaas-admin alice bob charlie diana; do
  user_ns="user-${user}"
  if oc get namespace "${user_ns}" &>/dev/null 2>&1; then
    info "  Namespace ${user_ns} already exists"
  else
    oc create namespace "${user_ns}" --dry-run=client -o yaml | oc apply -f - &>/dev/null
    # Label namespace so plugin's namespaceSelector can match it
    oc label namespace "${user_ns}" \
      "kubernetes.io/metadata.name=${user_ns}" \
      "rhai-tmm.dev/owner=${user}" \
      opendatahub.io/dashboard=true \
      kueue-managed=true \
      kueue.openshift.io/managed=true \
      modelmesh-enabled=false \
      --overwrite &>/dev/null || true
    success "  Created: ${user_ns}"
  fi
done
# Grant each user admin access to their booking namespace (required for RHOAI visibility)
for pair in "alice:user-alice" "bob:user-bob" "charlie:user-charlie" "diana:user-diana" "gpuaas-admin:user-gpuaas-admin"; do
  user="${pair%%:*}"
  ns="${pair##*:}"
  oc create rolebinding "${user}-admin" --clusterrole=admin --user="${user}" -n "${ns}"     --dry-run=client -o yaml | oc apply -f - &>/dev/null || true
done
success "User namespaces ready (with RHOAI access)"

# ── Print access info ─────────────────────────────────────────────────────────
OCP_APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.<cluster-domain>")

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           === UC10: GPU Booking Plugin — READY ===               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  GPU_TYPE       : ${GPU_TYPE}  (${GPU_MEMORY})"
echo "  StorageClass   : ${DEFAULT_STORAGECLASS}"
echo "  GPU resources  : Full GPU × ${GPU_FULL_COUNT}, Small MIG × ${MIG_SMALL_COUNT}, Large MIG × ${MIG_LARGE_COUNT}"
echo ""
echo "  Access via OCP Console:"
echo "    https://console-openshift-console.${OCP_APPS_DOMAIN}"
echo "    → Navigate to: GPU Bookings (left nav, added by plugin)"
echo ""
echo "  Teardown:"
echo "    helm uninstall gpu-booking-plugin -n ${NS}"
echo "    oc delete namespace ${NS}"
echo ""

# ── Deploy HardwareProfile watcher (instant RHOAI label on booking) ──────────
# The booking plugin creates HardwareProfiles without RHOAI discovery labels.
# This watcher reacts instantly (< 1s) when a new profile appears in any
# user-* namespace and adds the labels RHOAI Dashboard needs to show them.
info "Deploying HardwareProfile watcher..."
oc apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: booking-profile-labeler
  namespace: gpu-booking-app-plugin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: booking-profile-labeler
  template:
    metadata:
      labels:
        app: booking-profile-labeler
    spec:
      serviceAccountName: gpu-booking-plugin
      restartPolicy: Always
      containers:
        - name: labeler
          image: quay.io/openshift/origin-cli:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "Watching for new HardwareProfiles in user-* namespaces..."
              oc get hardwareprofile -A --watch --no-headers 2>/dev/null | \
              while read -r ns name rest; do
                if echo "$ns" | grep -q '^user-'; then
                  oc label hardwareprofile "$name" -n "$ns" \
                    app.kubernetes.io/part-of=hardwareprofile \
                    app.opendatahub.io/hardwareprofile=true \
                    --overwrite 2>/dev/null && \
                  echo "$(date): Labeled $ns/$name"
                fi
              done
YAML
success "HardwareProfile watcher deployed (instant label on new bookings)"
