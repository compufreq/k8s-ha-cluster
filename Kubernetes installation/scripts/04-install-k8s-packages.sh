#!/usr/bin/env bash
# ============================================================
# Step 3: Install kubeadm, kubelet, kubectl on K8s nodes
# Run this on control plane + worker nodes (NOT the load balancer)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

for i in "${!K8S_NODE_IPS[@]}"; do
    ip="${K8S_NODE_IPS[$i]}"
    host="${K8S_NODE_HOSTS[$i]}"
    log "Installing Kubernetes ${K8S_VERSION} packages on ${host} (${ip})..."

    run_on "$ip" "bash -s" <<EOF
        set -euo pipefail

        # Add Kubernetes apt repository
        sudo apt-get update -qq
        sudo apt-get install -y apt-transport-https ca-certificates curl gpg

        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
            | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
            | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

        # Install packages
        sudo apt-get update -qq
        sudo apt-get install -y kubelet kubeadm kubectl

        # Pin versions to prevent accidental upgrades
        sudo apt-mark hold kubelet kubeadm kubectl

        # Enable kubelet (it will crashloop until kubeadm init/join)
        sudo systemctl enable kubelet

        echo "  kubeadm \$(kubeadm version -o short) installed on \$(hostname)"
EOF
done

log "Kubernetes packages installed on all K8s nodes."
