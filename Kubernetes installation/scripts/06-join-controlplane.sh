#!/usr/bin/env bash
# ============================================================
# Step 5: Join the second control plane node to the cluster
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Check that join info exists
if [[ ! -f "${JOIN_INFO_DIR}/cp-join-cmd.sh" ]]; then
    err "Join command not found. Run 04-init-cluster.sh first."
    exit 1
fi

CP_JOIN_CMD=$(cat "${JOIN_INFO_DIR}/cp-join-cmd.sh")

log "Joining ${CP2_HOST} (${CP2_IP}) as control plane..."

run_on "$CP2_IP" "bash -s" <<EOF
    set -euo pipefail
    ${CP_JOIN_CMD} --apiserver-advertise-address '${CP2_IP}'
EOF

# Set up kubectl on CP2
log "Configuring kubectl on ${CP2_HOST}..."
run_on "$CP2_IP" "bash -s" <<'REMOTE'
    mkdir -p $HOME/.kube
    sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
REMOTE

log "${CP2_HOST} joined as control plane successfully!"

# Verify from CP1
log "Verifying nodes..."
run_on "$CP1_IP" "kubectl get nodes -o wide"
