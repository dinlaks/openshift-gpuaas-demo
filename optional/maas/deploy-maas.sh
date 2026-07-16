#!/usr/bin/env bash
# MaaS Setup — IBM Granite 3.1 2B on Cluster A GPU 1 (full A30, 24GB)
#
# Deploys a centrally hosted LLM endpoint. alice, bob, charlie access via
# individual API tokens — one GPU serves all three.
#
# Pre-req:
#   - GPU 1 on Cluster A must be in non-MIG mode (full A30)
#   - DRA must NOT be active (teardown-dra.sh first if running)
#   - RHOAI 3.3 deployed and healthy
#
# Recommended: Deploy Granite from RHOAI Dashboard → Model Catalog → maas-project
#   Hardware profile: gpu-a30-full-maas
#   Token auth: ✅ (service accounts: alice-token, bob-token, charlie-token)
# Then run this script to generate tokens and test the endpoint.
#
# Or: apply all YAMLs directly (see Usage below)
#
# Usage:
#   bash 08-maas/deploy-maas.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_env
OCP_API_URL="${CLUSTER_A_API_URL}"
OCP_USERNAME="${CLUSTER_A_USERNAME}"
OCP_PASSWORD="${CLUSTER_A_PASSWORD}"
require_oc_login

header "MaaS Setup — Granite 3.1 2B on Cluster A"

# ── 1. Project, RBAC, hardware profile ────────────────────────────────────────
info "Creating maas-project, RBAC, and hardware profile ..."
apply_cr "${SCRIPT_DIR}/01-maas-project.yaml"
success "maas-project ready"

# ── 2. ServingRuntime ─────────────────────────────────────────────────────────
info "Applying vLLM ServingRuntime ..."
apply_cr "${SCRIPT_DIR}/02-serving-runtime.yaml"
success "ServingRuntime applied"

# ── 3. InferenceService ───────────────────────────────────────────────────────
info "Deploying Granite 3.1 2B InferenceService ..."
info "(First run downloads ~5GB from HuggingFace — allow 5-10 min)"
apply_cr "${SCRIPT_DIR}/03-inference-service.yaml"

# ── 4. Per-user ServiceAccount tokens ─────────────────────────────────────────
info "Creating per-user API tokens ..."
apply_cr "${SCRIPT_DIR}/04-user-tokens.yaml"

wait_for "InferenceService Ready" \
  "oc get inferenceservice granite-maas -n maas-project -o jsonpath='{.status.modelStatus.states.targetModelState}' 2>/dev/null | grep -q Loaded" \
  600 20

# ── 5. Generate token secrets and save ────────────────────────────────────────
info "Generating API tokens for alice, bob, charlie ..."
for user in alice bob charlie; do
  TOKEN=$(oc create token ${user}-token -n maas-project --duration=24h 2>/dev/null)
  echo "${TOKEN}" > "/tmp/maas-token-${user}.txt"
  success "Token for ${user} saved to /tmp/maas-token-${user}.txt"
done

ENDPOINT=$(oc get inferenceservice granite-maas -n maas-project \
  -o jsonpath='{.status.url}' 2>/dev/null || echo "pending")
ISVC="granite-maas"

echo ""
success "MaaS ready!"
echo ""
info "  Endpoint : ${ENDPOINT}"
info "  Model    : ${ISVC}"
echo ""
info "Test with alice:"
echo "  ALICE_TOKEN=\$(cat /tmp/maas-token-alice.txt)"
echo "  curl -sk ${ENDPOINT}/v1/chat/completions \\"
echo "    -H \"Authorization: Bearer \${ALICE_TOKEN}\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"model\":\"${ISVC}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is OpenShift AI in one sentence?\"}]}' \\"
echo "    | python3 -c \"import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])\""
