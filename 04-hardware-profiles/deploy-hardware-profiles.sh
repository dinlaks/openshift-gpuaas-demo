#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Dinesh Lakshmanan
# Deploy RHOAI HardwareProfile CRs.
# GPU_TYPE in env.sh drives which resource names appear in each profile.
#
# Usage:
#   bash deploy-hardware-profiles.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_env
resolve_gpu_config   # sets MIG_SMALL_RESOURCE, MIG_LARGE_RESOURCE, FULL_GPU_RESOURCE from GPU_TYPE
require_oc_login

header "Hardware Profiles (GPU_TYPE=${GPU_TYPE})"

apply_cr    "${SCRIPT_DIR}/01-hp-cpu-only.yaml"
apply_template "${SCRIPT_DIR}/02-hp-mig-small.yaml"
apply_template "${SCRIPT_DIR}/03-hp-mig-large.yaml"
apply_template "${SCRIPT_DIR}/04-hp-gpu-full.yaml"

success "Hardware profiles deployed"
info "Verify: oc get hardwareprofiles -A"
