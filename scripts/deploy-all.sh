#!/usr/bin/env bash
# ============================================================
# Master Orchestration Script
# Deploys the full Kubernetes HA cluster from your Mac.
#
# Usage:
#   ./deploy-all.sh              # Run all steps
#   ./deploy-all.sh --from 4     # Resume from step 4
#   ./deploy-all.sh --step 7     # Run only step 7
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

FROM_STEP=1
ONLY_STEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) FROM_STEP="$2"; shift 2 ;;
        --step) ONLY_STEP="$2"; shift 2 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

should_run() {
    local step=$1
    if [[ $ONLY_STEP -gt 0 ]]; then
        [[ $step -eq $ONLY_STEP ]]
    else
        [[ $step -ge $FROM_STEP ]]
    fi
}

run_step() {
    local step=$1
    local name=$2
    local script=$3

    if should_run "$step"; then
        log "=========================================="
        log "  Step ${step}: ${name}"
        log "=========================================="
        bash "${SCRIPT_DIR}/${script}"
        log "Step ${step} complete."
        echo ""
    else
        echo "  Skipping step ${step}: ${name}"
    fi
}

echo ""
echo "============================================================"
echo "  Kubernetes HA Cluster Deployment"
echo "============================================================"
echo ""
echo "  Architecture:"
echo "    LB:  ${LB_HOST} (${LB_IP})"
echo "    CP1: ${CP1_HOST} (${CP1_IP})"
echo "    CP2: ${CP2_HOST} (${CP2_IP})"
echo "    W1:  ${W1_HOST} (${W1_IP})"
echo "    W2:  ${W2_HOST} (${W2_IP})"
echo ""
echo "  Kubernetes: v${K8S_VERSION}"
echo "  CNI:        Calico ${CALICO_VERSION}"
echo "  SSH User:   ${SSH_USER}"
echo ""

# Preflight: test SSH connectivity to all nodes
log "Preflight: Testing SSH connectivity..."
for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    host="${ALL_HOSTS[$i]}"
    if run_on "$ip" "echo ok" > /dev/null 2>&1; then
        echo "  + ${host} (${ip}): connected"
    else
        err "Cannot SSH to ${host} (${ip}) as ${SSH_USER}"
        err "Fix SSH connectivity and retry."
        exit 1
    fi
done
log "All nodes reachable."

run_step 1  "Configure /etc/hosts"           "01-setup-hosts.sh"
run_step 2  "Configure UFW Firewall"         "02-setup-firewall.sh"
run_step 3  "Setup HAProxy Load Balancer"    "03-setup-haproxy.sh"
run_step 4  "Install Kubernetes Packages"    "04-install-k8s-packages.sh"
run_step 5  "Initialize Cluster (CP1)"       "05-init-cluster.sh"
run_step 6  "Join Control Plane 2"           "06-join-controlplane.sh"
run_step 7  "Join Worker Nodes"              "07-join-workers.sh"
run_step 8  "Install Calico CNI"             "08-install-calico.sh"
run_step 9  "Verify Cluster Health"          "09-verify.sh"
run_step 10 "Verify Certificates"            "10-setup-certs.sh"

echo ""
log "============================================================"
log "  Deployment Complete!"
log "============================================================"
log ""
log "  To use kubectl from your Mac:"
log "    export KUBECONFIG=${JOIN_INFO_DIR}/admin.conf"
log "    kubectl get nodes"
log ""
log "  Or merge into your default kubeconfig:"
log "    cp ${JOIN_INFO_DIR}/admin.conf ~/.kube/config"
log ""
log "  HAProxy stats: http://${LB_IP}:8404/stats"
log ""
