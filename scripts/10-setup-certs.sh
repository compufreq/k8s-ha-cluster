#!/usr/bin/env bash
# ============================================================
# Step 9: Certificate verification and management
#
# kubeadm generates a full PKI during "kubeadm init":
#   /etc/kubernetes/pki/
#   ├── ca.crt / ca.key                  ← Cluster root CA
#   ├── apiserver.crt / apiserver.key    ← API server TLS
#   ├── apiserver-kubelet-client.crt     ← API→kubelet auth
#   ├── front-proxy-ca.crt / .key       ← Front-proxy CA
#   ├── front-proxy-client.crt / .key   ← Aggregation layer
#   ├── sa.key / sa.pub                  ← Service account signing
#   └── etcd/
#       ├── ca.crt / ca.key             ← etcd CA
#       ├── server.crt / server.key     ← etcd TLS
#       ├── peer.crt / peer.key         ← etcd peer TLS
#       └── healthcheck-client.crt/key  ← etcd health checks
#
# This script:
#   - Verifies all certificates exist on both control planes
#   - Checks expiry dates (kubeadm certs expire after 1 year)
#   - Validates the CA is consistent across control planes
#   - Provides renewal commands
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

PASS=0
FAIL=0
WARN=0

check_pass() { echo "    ✅ $1"; ((PASS++)); }
check_fail() { echo "    ❌ $1"; ((FAIL++)); }
check_warn() { echo "    ⚠️  $1"; ((WARN++)); }

# ──────────────────────────────────────────────
# 1. Verify PKI files exist on both control planes
# ──────────────────────────────────────────────
log "1. Verifying PKI files on control planes..."

EXPECTED_FILES=(
    "ca.crt" "ca.key"
    "apiserver.crt" "apiserver.key"
    "apiserver-kubelet-client.crt" "apiserver-kubelet-client.key"
    "apiserver-etcd-client.crt" "apiserver-etcd-client.key"
    "front-proxy-ca.crt" "front-proxy-ca.key"
    "front-proxy-client.crt" "front-proxy-client.key"
    "sa.key" "sa.pub"
    "etcd/ca.crt" "etcd/ca.key"
    "etcd/server.crt" "etcd/server.key"
    "etcd/peer.crt" "etcd/peer.key"
    "etcd/healthcheck-client.crt" "etcd/healthcheck-client.key"
)

for i in "${!CP_IPS[@]}"; do
    ip="${CP_IPS[$i]}"
    host="${CP_HOSTS[$i]}"
    echo ""
    echo "  ${host} (${ip}):"

    for f in "${EXPECTED_FILES[@]}"; do
        if run_on "$ip" "sudo test -f /etc/kubernetes/pki/${f}" 2>/dev/null; then
            check_pass "${f}"
        else
            check_fail "${f} — MISSING"
        fi
    done
done

# ──────────────────────────────────────────────
# 2. Check certificate expiry dates
# ──────────────────────────────────────────────
log "2. Certificate expiry dates (from ${CP1_HOST})..."

echo ""
run_on "$CP1_IP" "sudo kubeadm certs check-expiration 2>/dev/null" || \
    run_on "$CP1_IP" "sudo kubeadm alpha certs check-expiration 2>/dev/null" || \
    warn "Could not run kubeadm certs check-expiration"

# Check if any cert expires within 30 days
echo ""
echo "  Checking for certs expiring within 30 days..."
CERTS_TO_CHECK=("ca" "apiserver" "apiserver-kubelet-client" "front-proxy-ca" "front-proxy-client" "apiserver-etcd-client" "etcd/ca" "etcd/server" "etcd/peer" "etcd/healthcheck-client")

THRESHOLD_DAYS=30
THRESHOLD_SECS=$((THRESHOLD_DAYS * 86400))
NOW=$(date +%s)

for cert in "${CERTS_TO_CHECK[@]}"; do
    EXPIRY=$(run_on "$CP1_IP" "sudo openssl x509 -in /etc/kubernetes/pki/${cert}.crt -noout -enddate 2>/dev/null | cut -d= -f2" || echo "")
    if [[ -n "$EXPIRY" ]]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo "0")
        REMAINING=$(( EXPIRY_EPOCH - NOW ))
        DAYS_LEFT=$(( REMAINING / 86400 ))
        if [[ $REMAINING -lt $THRESHOLD_SECS ]]; then
            check_warn "${cert}.crt expires in ${DAYS_LEFT} days!"
        else
            check_pass "${cert}.crt — ${DAYS_LEFT} days remaining"
        fi
    fi
done

# ──────────────────────────────────────────────
# 3. Validate CA consistency across control planes
# ──────────────────────────────────────────────
log "3. Validating CA consistency across control planes..."

CA_FILES=("ca.crt" "front-proxy-ca.crt" "etcd/ca.crt" "sa.pub")
for ca in "${CA_FILES[@]}"; do
    HASH_CP1=$(run_on "$CP1_IP" "sudo sha256sum /etc/kubernetes/pki/${ca} 2>/dev/null | awk '{print \$1}'" || echo "none1")
    HASH_CP2=$(run_on "$CP2_IP" "sudo sha256sum /etc/kubernetes/pki/${ca} 2>/dev/null | awk '{print \$1}'" || echo "none2")
    if [[ "$HASH_CP1" == "$HASH_CP2" && "$HASH_CP1" != "none1" ]]; then
        check_pass "${ca} — matches on both control planes"
    else
        check_fail "${ca} — MISMATCH between control planes!"
    fi
done

# ──────────────────────────────────────────────
# 4. Verify API server certificate SANs
# ──────────────────────────────────────────────
log "4. API server certificate SANs (Subject Alternative Names)..."

echo ""
echo "  The API server cert should include the LB IP and both CP IPs."
echo ""
SANS=$(run_on "$CP1_IP" "sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name'" || echo "")
echo "  ${SANS}"
echo ""

for expected_ip in "$LB_IP" "$CP1_IP" "$CP2_IP"; do
    if echo "$SANS" | grep -q "$expected_ip"; then
        check_pass "SAN includes ${expected_ip}"
    else
        check_warn "SAN missing ${expected_ip} — may need to regenerate apiserver cert"
    fi
done

# Check that the kubernetes service IP (first IP in service CIDR) is included
# Default: 10.96.0.1
if echo "$SANS" | grep -q "10.96.0.1"; then
    check_pass "SAN includes kubernetes service IP (10.96.0.1)"
fi

# ──────────────────────────────────────────────
# 5. Verify kubelet client certificates on workers
# ──────────────────────────────────────────────
log "5. Kubelet client certificates on worker nodes..."

for i in "${!WORKER_IPS[@]}"; do
    ip="${WORKER_IPS[$i]}"
    host="${WORKER_HOSTS[$i]}"
    echo ""
    echo "  ${host} (${ip}):"

    if run_on "$ip" "sudo test -f /var/lib/kubelet/pki/kubelet-client-current.pem" 2>/dev/null; then
        check_pass "kubelet-client-current.pem exists"
        EXPIRY=$(run_on "$ip" "sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate 2>/dev/null | cut -d= -f2" || echo "unknown")
        echo "      Expires: ${EXPIRY}"
    else
        check_warn "kubelet-client-current.pem not found (may use bootstrap token)"
    fi

    if run_on "$ip" "sudo test -f /etc/kubernetes/kubelet.conf" 2>/dev/null; then
        check_pass "kubelet.conf exists"
    else
        check_fail "kubelet.conf MISSING"
    fi
done

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
log "============================================"
log "  Certificate Check Results"
log "  ✅ Passed: ${PASS}   ⚠️  Warnings: ${WARN}   ❌ Failed: ${FAIL}"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    err "Some certificate checks failed. See output above."
fi

if [[ $WARN -gt 0 ]]; then
    echo ""
    warn "Certificate renewal commands (run on each control plane):"
    echo ""
    echo "  # Renew all certificates:"
    echo "  sudo kubeadm certs renew all"
    echo ""
    echo "  # Renew a specific certificate:"
    echo "  sudo kubeadm certs renew apiserver"
    echo ""
    echo "  # After renewal, restart control plane components:"
    echo "  sudo systemctl restart kubelet"
    echo ""
    echo "  # Update kubeconfig files after CA renewal:"
    echo "  sudo kubeadm kubeconfig user --client-name=admin --org=system:masters > admin.conf"
fi
