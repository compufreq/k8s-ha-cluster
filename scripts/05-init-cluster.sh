#!/usr/bin/env bash
# ============================================================
# Step 4: Initialize the Kubernetes cluster on Control Plane 1
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

mkdir -p "$JOIN_INFO_DIR"

log "Initializing Kubernetes cluster on ${CP1_HOST} (${CP1_IP})..."
log "Control plane endpoint: ${CONTROL_PLANE_ENDPOINT} (via HAProxy)"
log "Pod CIDR: ${POD_CIDR}"

# Run kubeadm init and capture output
INIT_OUTPUT=$(run_on "$CP1_IP" "sudo kubeadm init \
    --control-plane-endpoint '${CONTROL_PLANE_ENDPOINT}' \
    --upload-certs \
    --pod-network-cidr '${POD_CIDR}' \
    --apiserver-advertise-address '${CP1_IP}'" 2>&1) || {
    err "kubeadm init failed!"
    echo "$INIT_OUTPUT"
    exit 1
}

echo "$INIT_OUTPUT"

# Save the full output for reference
echo "$INIT_OUTPUT" > "${JOIN_INFO_DIR}/kubeadm-init-output.txt"

# Extract the certificate key
CERT_KEY=$(echo "$INIT_OUTPUT" | grep -A2 "certificate-key" | grep -oP '[a-f0-9]{64}' | head -1)
echo "$CERT_KEY" > "${JOIN_INFO_DIR}/certificate-key.txt"

# Extract the discovery token CA cert hash
CA_CERT_HASH=$(echo "$INIT_OUTPUT" | grep "discovery-token-ca-cert-hash" | head -1 | grep -oP 'sha256:[a-f0-9]+')
echo "$CA_CERT_HASH" > "${JOIN_INFO_DIR}/ca-cert-hash.txt"

# Get a fresh join token
JOIN_TOKEN=$(run_on "$CP1_IP" "sudo kubeadm token create")
echo "$JOIN_TOKEN" > "${JOIN_INFO_DIR}/token.txt"

# Build join commands
WORKER_JOIN="sudo kubeadm join ${CONTROL_PLANE_ENDPOINT} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${CA_CERT_HASH}"
CP_JOIN="${WORKER_JOIN} --control-plane --certificate-key ${CERT_KEY}"

echo "$WORKER_JOIN" > "${JOIN_INFO_DIR}/worker-join-cmd.sh"
echo "$CP_JOIN" > "${JOIN_INFO_DIR}/cp-join-cmd.sh"

# Set up kubectl for the SSH user on CP1
log "Configuring kubectl on ${CP1_HOST}..."
run_on "$CP1_IP" "bash -s" <<'REMOTE'
    mkdir -p $HOME/.kube
    sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
REMOTE

# Copy kubeconfig to local Mac
log "Copying kubeconfig to local machine..."
mkdir -p "$HOME/.kube"
run_on "$CP1_IP" "sudo cat /etc/kubernetes/admin.conf" > "${JOIN_INFO_DIR}/admin.conf"

# Update the server address in kubeconfig to point to the load balancer
sed -i.bak "s|server: https://${CP1_IP}:6443|server: https://${LB_IP}:6443|" "${JOIN_INFO_DIR}/admin.conf" 2>/dev/null || \
sed -i '' "s|server: https://${CP1_IP}:6443|server: https://${LB_IP}:6443|" "${JOIN_INFO_DIR}/admin.conf"

log "Cluster initialized successfully!"
log "Join info saved to: ${JOIN_INFO_DIR}/"
log "Kubeconfig saved to: ${JOIN_INFO_DIR}/admin.conf"
log ""
log "To use kubectl from your Mac:"
log "  export KUBECONFIG=${JOIN_INFO_DIR}/admin.conf"
log "  kubectl get nodes"
