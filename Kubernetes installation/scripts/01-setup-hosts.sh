#!/usr/bin/env bash
# ============================================================
# Step 1: Configure /etc/hosts on all nodes
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

HOSTS_BLOCK="# --- Kubernetes Cluster Nodes ---
${LB_IP}  ${LB_HOST}
${CP1_IP}  ${CP1_HOST}
${CP2_IP}  ${CP2_HOST}
${W1_IP}  ${W1_HOST}
${W2_IP}  ${W2_HOST}
# --- End Kubernetes Cluster Nodes ---"

for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    host="${ALL_HOSTS[$i]}"
    log "Configuring /etc/hosts on ${host} (${ip})..."

    run_on "$ip" "bash -s" <<EOF
        sudo sed -i '/# --- Kubernetes Cluster Nodes ---/,/# --- End Kubernetes Cluster Nodes ---/d' /etc/hosts
        sudo sed -i -e '/loadbalancersrv/d' -e '/controlplane[12]/d' -e '/node0[12]/d' /etc/hosts
        echo '${HOSTS_BLOCK}' | sudo tee -a /etc/hosts > /dev/null
        echo "  Done on \$(hostname)"
EOF
done

log "Verifying connectivity..."
for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    host="${ALL_HOSTS[$i]}"
    echo "  From ${host}:"
    for target in "${ALL_HOSTS[@]}"; do
        run_on "$ip" "ping -c1 -W2 ${target} > /dev/null 2>&1 && echo '    + ${target} OK' || echo '    - ${target} FAIL'"
    done
done

log "Hosts configuration complete."
