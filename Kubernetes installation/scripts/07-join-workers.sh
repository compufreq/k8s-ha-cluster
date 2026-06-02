#!/usr/bin/env bash
# ============================================================
# Step 6: Join worker nodes to the cluster
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Check that join info exists
if [[ ! -f "${JOIN_INFO_DIR}/worker-join-cmd.sh" ]]; then
    err "Join command not found. Run 04-init-cluster.sh first."
    exit 1
fi

WORKER_JOIN_CMD=$(cat "${JOIN_INFO_DIR}/worker-join-cmd.sh")

for i in "${!WORKER_IPS[@]}"; do
    ip="${WORKER_IPS[$i]}"
    host="${WORKER_HOSTS[$i]}"
    log "Joining ${host} (${ip}) as worker..."

    run_on "$ip" "bash -s" <<EOF
        set -euo pipefail
        ${WORKER_JOIN_CMD}
EOF

    log "${host} joined as worker."
done

# Verify from CP1
log "Verifying all nodes..."
sleep 5
run_on "$CP1_IP" "kubectl get nodes -o wide"

log "All workers joined successfully!"
