#!/usr/bin/env bash
# ============================================================
# Step 7: Install Calico CNI
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log "Installing Calico ${CALICO_VERSION} on the cluster..."

run_on "$CP1_IP" "bash -s" <<EOF
    set -euo pipefail

    # Install the Tigera Calico operator
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml

    # Wait for the operator to be ready
    echo "Waiting for Tigera operator..."
    kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=120s || true

    # Install Calico custom resources (uses default 192.168.0.0/16 CIDR)
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml
EOF

log "Waiting for Calico pods to start (this may take 2-3 minutes)..."
sleep 30

# Poll until calico-system pods are running
for attempt in $(seq 1 12); do
    READY=$(run_on "$CP1_IP" "kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c Running || echo 0")
    TOTAL=$(run_on "$CP1_IP" "kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0")
    log "Calico pods: ${READY}/${TOTAL} running (attempt ${attempt}/12)"

    if [[ "$READY" -gt 0 && "$READY" == "$TOTAL" ]]; then
        break
    fi
    sleep 15
done

run_on "$CP1_IP" "kubectl get pods -n calico-system"

log "Calico CNI installation complete."

# Check node status
log "Node status:"
run_on "$CP1_IP" "kubectl get nodes -o wide"
