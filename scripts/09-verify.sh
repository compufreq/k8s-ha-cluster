#!/usr/bin/env bash
# ============================================================
# Step 8: Verify cluster health
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    echo -n "  ${desc}... "
    if "$@" > /dev/null 2>&1; then
        echo "OK"
        ((PASS++))
    else
        echo "FAIL"
        ((FAIL++))
    fi
}

log "============================================"
log "  Kubernetes Cluster Health Check"
log "============================================"

# 1. HAProxy
log "1. HAProxy Load Balancer (${LB_HOST})"
check "HAProxy service running" run_on "$LB_IP" "systemctl is-active haproxy"
check "Port 6443 listening" run_on "$LB_IP" "ss -tlnp | grep -q 6443"

# 2. Node status
log "2. Node Status"
NODES=$(run_on "$CP1_IP" "kubectl get nodes --no-headers 2>/dev/null")
echo "$NODES"
echo ""

for host in "${K8S_NODE_HOSTS[@]}"; do
    check "Node ${host} is Ready" bash -c "echo '$NODES' | grep -q '${host}.*Ready'"
done

# 3. Control plane components
log "3. Control Plane Components"
for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    COUNT=$(run_on "$CP1_IP" "kubectl get pods -n kube-system --no-headers -l component=${component} 2>/dev/null | grep -c Running || echo 0")
    check "${component} running (${COUNT} instances)" test "$COUNT" -ge 1
done

# 4. Calico
log "4. Calico CNI"
CALICO_RUNNING=$(run_on "$CP1_IP" "kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c Running || echo 0")
CALICO_TOTAL=$(run_on "$CP1_IP" "kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0")
check "Calico pods (${CALICO_RUNNING}/${CALICO_TOTAL} running)" test "$CALICO_RUNNING" -eq "$CALICO_TOTAL"

# 5. CoreDNS
log "5. CoreDNS"
COREDNS_RUNNING=$(run_on "$CP1_IP" "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running || echo 0")
check "CoreDNS running (${COREDNS_RUNNING} pods)" test "$COREDNS_RUNNING" -ge 1

# 6. Cluster connectivity test
log "6. Connectivity Test"
check "API server via LB" run_on "$CP1_IP" "kubectl --server=https://${LB_IP}:6443 get nodes"

# 7. Quick deployment test
log "7. Deployment Smoke Test"
run_on "$CP1_IP" "kubectl delete deployment nginx-test --ignore-not-found > /dev/null 2>&1"
run_on "$CP1_IP" "kubectl create deployment nginx-test --image=nginx --replicas=2"
sleep 10
READY=$(run_on "$CP1_IP" "kubectl get deployment nginx-test -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0")
check "Test deployment (${READY}/2 ready)" test "$READY" -eq 2
run_on "$CP1_IP" "kubectl delete deployment nginx-test --ignore-not-found > /dev/null 2>&1"

# Summary
log "============================================"
log "  Results: ${PASS} passed, ${FAIL} failed"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    warn "Some checks failed. Review the output above."
    exit 1
else
    log "All checks passed! Your cluster is healthy."
fi
