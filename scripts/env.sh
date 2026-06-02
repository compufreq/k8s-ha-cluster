#!/usr/bin/env bash
# ============================================================
# Kubernetes HA Cluster - Environment Configuration
# ============================================================
# Modify these values to match your environment.

# SSH user for connecting to nodes (must have passwordless sudo)
SSH_USER="${SSH_USER:-$(whoami)}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# --- Load Balancer ---
LB_HOST="loadbalancersrv"
LB_IP="10.10.10.10"

# --- Control Plane Nodes ---
CP1_HOST="controlplane1"
CP1_IP="10.10.10.11"

CP2_HOST="controlplane2"
CP2_IP="10.10.10.12"

# --- Worker Nodes ---
W1_HOST="node01"
W1_IP="10.10.10.14"

W2_HOST="node02"
W2_IP="10.10.10.15"

# --- Grouped Arrays ---
ALL_IPS=("$LB_IP" "$CP1_IP" "$CP2_IP" "$W1_IP" "$W2_IP")
ALL_HOSTS=("$LB_HOST" "$CP1_HOST" "$CP2_HOST" "$W1_HOST" "$W2_HOST")

K8S_NODE_IPS=("$CP1_IP" "$CP2_IP" "$W1_IP" "$W2_IP")
K8S_NODE_HOSTS=("$CP1_HOST" "$CP2_HOST" "$W1_HOST" "$W2_HOST")

CP_IPS=("$CP1_IP" "$CP2_IP")
CP_HOSTS=("$CP1_HOST" "$CP2_HOST")

WORKER_IPS=("$W1_IP" "$W2_IP")
WORKER_HOSTS=("$W1_HOST" "$W2_HOST")

# --- Kubernetes Settings ---
K8S_VERSION="1.35"
POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CONTROL_PLANE_ENDPOINT="${LB_IP}:6443"

# --- Calico ---
CALICO_VERSION="v3.29.0"

# --- Join Info (populated by 04-init-cluster.sh) ---
JOIN_INFO_DIR="/tmp/k8s-join-info"

# --- Helper Functions ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\n\033[1;32m>>>\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }

run_on() {
    local ip="$1"; shift
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"
}
