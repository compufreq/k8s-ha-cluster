#!/usr/bin/env bash
# ============================================================
# Step 2: Configure UFW firewall rules on all nodes
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# -------------------------------------------------------
# Load Balancer
# -------------------------------------------------------
log "Configuring firewall on ${LB_HOST} (${LB_IP})..."

run_on "$LB_IP" "bash -s" <<'REMOTE'
    set -euo pipefail
    sudo ufw allow ssh
    sudo ufw allow 6443/tcp   comment 'K8s API via HAProxy'
    sudo ufw allow 8404/tcp   comment 'HAProxy stats dashboard'
    sudo ufw --force enable
    sudo ufw reload
    echo "  UFW rules on $(hostname):"
    sudo ufw status numbered
REMOTE

# -------------------------------------------------------
# Control Plane nodes
# -------------------------------------------------------
for i in "${!CP_IPS[@]}"; do
    ip="${CP_IPS[$i]}"
    host="${CP_HOSTS[$i]}"
    log "Configuring firewall on ${host} (${ip})..."

    run_on "$ip" "bash -s" <<'REMOTE'
        set -euo pipefail
        sudo ufw allow ssh

        # --- Kubernetes control plane ---
        sudo ufw allow 6443/tcp        comment 'K8s API server'
        sudo ufw allow 2379:2380/tcp   comment 'etcd client & peer'
        sudo ufw allow 10250/tcp       comment 'Kubelet API'
        sudo ufw allow 10257/tcp       comment 'kube-controller-manager'
        sudo ufw allow 10259/tcp       comment 'kube-scheduler'
        sudo ufw allow 10256/tcp       comment 'kube-proxy health check'

        # --- Calico CNI ---
        sudo ufw allow 179/tcp         comment 'Calico BGP'
        sudo ufw allow 4789/udp        comment 'Calico VXLAN'
        sudo ufw allow 5473/tcp        comment 'Calico Typha'

        sudo ufw --force enable
        sudo ufw reload
        echo "  UFW rules on $(hostname):"
        sudo ufw status numbered
REMOTE
done

# -------------------------------------------------------
# Worker nodes
# -------------------------------------------------------
for i in "${!WORKER_IPS[@]}"; do
    ip="${WORKER_IPS[$i]}"
    host="${WORKER_HOSTS[$i]}"
    log "Configuring firewall on ${host} (${ip})..."

    run_on "$ip" "bash -s" <<'REMOTE'
        set -euo pipefail
        sudo ufw allow ssh

        # --- Kubernetes worker ---
        sudo ufw allow 10250/tcp       comment 'Kubelet API'
        sudo ufw allow 10256/tcp       comment 'kube-proxy health check'
        sudo ufw allow 30000:32767/tcp comment 'NodePort services'

        # --- Calico CNI ---
        sudo ufw allow 179/tcp         comment 'Calico BGP'
        sudo ufw allow 4789/udp        comment 'Calico VXLAN'
        sudo ufw allow 5473/tcp        comment 'Calico Typha'

        sudo ufw --force enable
        sudo ufw reload
        echo "  UFW rules on $(hostname):"
        sudo ufw status numbered
REMOTE
done

log "Firewall configured on all nodes."
