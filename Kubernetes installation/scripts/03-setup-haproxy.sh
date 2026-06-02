#!/usr/bin/env bash
# ============================================================
# Step 2: Install and configure HAProxy on the load balancer
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log "Installing HAProxy on ${LB_HOST} (${LB_IP})..."

# Install HAProxy
run_on "$LB_IP" "bash -s" <<'INSTALL'
    sudo apt-get update -qq
    sudo apt-get install -y haproxy
    sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
INSTALL

# Generate and deploy config (variables expanded locally)
HAPROXY_CFG="global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

# ----- Kubernetes API Server -----
frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server ${CP1_HOST} ${CP1_IP}:6443 check fall 3 rise 2
    server ${CP2_HOST} ${CP2_IP}:6443 check fall 3 rise 2

# ----- Stats Dashboard (http://${LB_IP}:8404/stats) -----
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s"

echo "$HAPROXY_CFG" | run_on "$LB_IP" "sudo tee /etc/haproxy/haproxy.cfg > /dev/null"

# Enable and start
run_on "$LB_IP" "sudo systemctl enable haproxy && sudo systemctl restart haproxy"

log "HAProxy setup complete."
log "Stats dashboard: http://${LB_IP}:8404/stats"
log "API endpoint:    ${LB_IP}:6443 -> ${CP1_IP}:6443, ${CP2_IP}:6443"
