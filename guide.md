# Kubernetes HA Cluster Setup Guide

## Architecture

```
                        +---------------------------+
                        |     loadbalancersrv       |
                        |       10.10.10.10         |
                        |       HAProxy (LB)        |
                        +------------+--------------+
                                     |
                                     | :6443
                          +----------+------------+
                          |                       |
               +----------+-------+    +----------+-------+
               |   controlplane1  |    |   controlplane2  |
               |    10.10.10.11   |    |    10.10.10.12   |
               | Control Plane 1  |    | Control Plane 2  |
               +------------------+    +------------------+

               +----------+-------+    +----------+-------+
               |      node01      |    |      node02      |
               |    10.10.10.14   |    |    10.10.10.15   |
               |     Worker 1     |    |     Worker 2     |
               +------------------+    +------------------+
```

| Hostname        | IP          | Role                  |
|-----------------|-------------|-----------------------|
| loadbalancersrv | 10.10.10.10 | HAProxy load balancer |
| controlplane1   | 10.10.10.11 | Control Plane 1       |
| controlplane2   | 10.10.10.12 | Control Plane 2       |
| node01          | 10.10.10.14 | Worker 1              |
| node02          | 10.10.10.15 | Worker 2              |

- **Load Balancer:** HAProxy on loadbalancersrv, round-robins API traffic to both control planes
- **Control Planes:** Run etcd, kube-apiserver, kube-controller-manager, kube-scheduler
- **Workers:** Run workloads (pods)
- **CNI:** Calico (pod CIDR: 192.168.0.0/16)
- **Kubernetes:** v1.35

---

## Prerequisites

The following steps must be completed on **all K8s nodes** (controlplane1, controlplane2, node01, node02) before proceeding.

### 1. Disable Swap

Kubelet will **refuse to start** if swap is enabled. This is one of the most common causes of join failures.

```bash
# Disable swap immediately
sudo swapoff -a

# Remove swap entries from fstab so it stays off after reboot
sudo sed -i '/swap/d' /etc/fstab

# If a swapfile exists, remove it
sudo rm -f /swap.img

# Verify swap is off (Swap line should show all zeros)
free -h
```

> **Warning:** If you skip this step, `kubeadm join` may appear to succeed but the kubelet will crash-loop with: `"failed to run Kubelet: running with swap on is not supported"`. This can cause misleading errors like etcd members failing to start on control plane joins.

### 2. Load Kernel Modules and Enable IP Forwarding

```bash
# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Enable IP forwarding and bridge traffic
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

**Verify IP forwarding is active:**

```bash
cat /proc/sys/net/ipv4/ip_forward
# Must return: 1
```

If it returns `0`, enable it immediately:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

> **Warning:** `kubeadm init` and `kubeadm join` will fail with a preflight error if `ip_forward` is not set to `1`: `"/proc/sys/net/ipv4/ip_forward contents are not set to 1"`. The sysctl.d config file ensures it persists across reboots, but always verify before running kubeadm commands.

### 3. Install and Configure containerd

```bash
sudo apt-get update
sudo apt-get install -y containerd

# Generate default config and enable SystemdCgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 4. Install crictl

```bash
CRICTL_VERSION="v1.35.0"
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" | sudo tar -C /usr/local/bin -xz

# Configure crictl to use containerd
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
```

---

## Step 1: Configure /etc/hosts on All Nodes

Add hostname-to-IP mappings so all nodes can resolve each other.

**Run on ALL 5 machines:**

```bash
cat <<EOF | sudo tee -a /etc/hosts
# --- Kubernetes Cluster Nodes ---
10.10.10.10  loadbalancersrv
10.10.10.11  controlplane1
10.10.10.12  controlplane2
10.10.10.14  node01
10.10.10.15  node02
# --- End Kubernetes Cluster Nodes ---
EOF
```

**Or use the automation script:**
```bash
./scripts/01-setup-hosts.sh
```

---

## Step 2: Configure UFW Firewall

Each node role requires different ports. Open only what's needed per role.

### Load Balancer (loadbalancersrv)

```bash
sudo ufw allow ssh
sudo ufw allow 6443/tcp    # K8s API — HAProxy listens here and forwards to control planes
sudo ufw allow 8404/tcp    # HAProxy stats dashboard
sudo ufw --force enable
sudo ufw reload
```

| Port | Protocol | Purpose                 |
|------|----------|-------------------------|
| 22   | TCP      | SSH                     |
| 6443 | TCP      | K8s API via HAProxy     |
| 8404 | TCP      | HAProxy stats dashboard |

### Control Planes (controlplane1, controlplane2)

```bash
sudo ufw allow ssh
# Kubernetes control plane
sudo ufw allow 6443/tcp        # API server
sudo ufw allow 2379:2380/tcp   # etcd client & peer communication
sudo ufw allow 10250/tcp       # Kubelet API
sudo ufw allow 10257/tcp       # kube-controller-manager
sudo ufw allow 10259/tcp       # kube-scheduler
sudo ufw allow 10256/tcp       # kube-proxy health check
# Calico CNI
sudo ufw allow 179/tcp         # BGP peering
sudo ufw allow 4789/udp        # VXLAN encapsulation
sudo ufw allow 5473/tcp        # Calico Typha
sudo ufw --force enable
sudo ufw reload
```

| Port      | Protocol | Purpose                 |
|-----------|----------|-------------------------|
| 22        | TCP      | SSH                     |
| 6443      | TCP      | API server              |
| 2379-2380 | TCP      | etcd client & peer      |
| 10250     | TCP      | Kubelet API             |
| 10257     | TCP      | kube-controller-manager |
| 10259     | TCP      | kube-scheduler          |
| 10256     | TCP      | kube-proxy health check |
| 179       | TCP      | Calico BGP              |
| 4789      | UDP      | Calico VXLAN            |
| 5473      | TCP      | Calico Typha            |

### Workers (node01, node02)

```bash
sudo ufw allow ssh
# Kubernetes worker
sudo ufw allow 10250/tcp       # Kubelet API
sudo ufw allow 10256/tcp       # kube-proxy health check
sudo ufw allow 30000:32767/tcp # NodePort services
# Calico CNI
sudo ufw allow 179/tcp         # BGP peering
sudo ufw allow 4789/udp        # VXLAN encapsulation
sudo ufw allow 5473/tcp        # Calico Typha
sudo ufw --force enable
sudo ufw reload
```

| Port        | Protocol | Purpose                 |
|-------------|----------|-------------------------|
| 22          | TCP      | SSH                     |
| 10250       | TCP      | Kubelet API             |
| 10256       | TCP      | kube-proxy health check |
| 30000-32767 | TCP      | NodePort services       |
| 179         | TCP      | Calico BGP              |
| 4789        | UDP      | Calico VXLAN            |
| 5473        | TCP      | Calico Typha            |

> **Tip:** If all nodes are on a trusted private network, you can simplify with:
> `sudo ufw allow from 10.10.10.0/24`

**Or use the automation script:**
```bash
./scripts/02-setup-firewall.sh
```

---

## Step 3: Set Up HAProxy Load Balancer

This runs **only on loadbalancersrv**. HAProxy will distribute API server traffic (port 6443) across both control planes.

**Run on loadbalancersrv:**

```bash
sudo apt-get update
sudo apt-get install -y haproxy
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
```

Create the config:

```bash
sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'EOF'
global
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

frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server controlplane1 10.10.10.11:6443 check fall 3 rise 2
    server controlplane2 10.10.10.12:6443 check fall 3 rise 2

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF
```

Start HAProxy:

```bash
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy
```

Verify: Open `http://10.10.10.10:8404/stats` in a browser (backends will show DOWN until the API servers start).

**Or use the automation script:**
```bash
./scripts/03-setup-haproxy.sh
```

---

## Step 4: Install kubeadm, kubelet, kubectl

**Run on controlplane1, controlplane2, node01, node02** (NOT on loadbalancersrv):

```bash
# Add Kubernetes apt repository
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

# Install
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# Prevent automatic upgrades
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet
sudo systemctl enable kubelet
```

**Or use the automation script:**
```bash
./scripts/04-install-k8s-packages.sh
```

---

## Step 5: Initialize the Cluster (Control Plane 1)

**Run on controlplane1 ONLY:**

```bash
sudo kubeadm init \
    --control-plane-endpoint "10.10.10.10:6443" \
    --upload-certs \
    --pod-network-cidr "192.168.0.0/16" \
    --apiserver-advertise-address "10.10.10.11"
```

### What this does (certificates / PKI)

`kubeadm init` generates a complete PKI under `/etc/kubernetes/pki/`:

```
/etc/kubernetes/pki/
├── ca.crt / ca.key                  <- Cluster root CA (signs all other certs)
├── apiserver.crt / apiserver.key    <- API server TLS serving cert
├── apiserver-kubelet-client.crt     <- API server -> kubelet client cert
├── apiserver-etcd-client.crt        <- API server -> etcd client cert
├── front-proxy-ca.crt / .key       <- Front-proxy CA (aggregation layer)
├── front-proxy-client.crt / .key   <- Front-proxy client cert
├── sa.key / sa.pub                  <- Service account token signing key pair
└── etcd/
    ├── ca.crt / ca.key             <- etcd-specific CA
    ├── server.crt / server.key     <- etcd TLS serving cert
    ├── peer.crt / peer.key         <- etcd peer-to-peer TLS
    └── healthcheck-client.crt/key  <- etcd health check client cert
```

Key points:
- **`--upload-certs`** encrypts and uploads CA keys to a kubeadm-certs Secret in kube-system. This allows CP2 to download them automatically during join (the secret is auto-deleted after 2 hours).
- The **certificate key** in the output is needed for control plane joins — it decrypts the uploaded certs.
- **API server SAN (Subject Alternative Names):** The apiserver cert automatically includes `10.10.10.10` (LB), `10.10.10.11` (CP1), `10.96.0.1` (kubernetes service IP), `localhost`, and the hostname.
- All component certs (apiserver, kubelet client, etcd, etc.) expire after **1 year**. The CA certs expire after **10 years**.

**Important:** The `--control-plane-endpoint` points to the HAProxy load balancer, NOT to this node directly. This is critical for HA — all kubeconfig files and join commands will reference the LB address.

After success, **save the output.** It contains join commands and the certificate key.

Set up kubectl:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Verify:

```bash
kubectl get nodes
# Should show controlplane1 with status NotReady (no CNI yet)
```

**Or use the automation script:**
```bash
./scripts/05-init-cluster.sh
```

---

## Step 6: Join Control Plane 2

**Run on controlplane2:**

Use the control plane join command from the `kubeadm init` output:

```bash
sudo kubeadm join 10.10.10.10:6443 \
    --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane \
    --certificate-key <certificate-key> \
    --apiserver-advertise-address "10.10.10.12"
```

### What happens with certificates during join

1. The `--discovery-token-ca-cert-hash` flag verifies the cluster CA's identity — this prevents man-in-the-middle attacks during the join.
2. The `--certificate-key` decrypts the CA keys from the kubeadm-certs Secret uploaded during init.
3. kubeadm then generates **new** certs for controlplane2 (apiserver, etcd peer/server, etc.) signed by the **same** cluster CA.
4. The etcd member on controlplane2 gets its own peer cert and is added to the etcd cluster.

After join, controlplane2 has its own `/etc/kubernetes/pki/` with:
- **Shared:** `ca.crt`, `ca.key`, `front-proxy-ca.crt/.key`, `etcd/ca.crt/.key`, `sa.key/.pub` (identical to controlplane1)
- **Unique:** `apiserver.crt/.key`, `etcd/server.crt/.key`, `etcd/peer.crt/.key` (generated fresh for this node)

Then set up kubectl on this node:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Or use the automation script:**
```bash
./scripts/06-join-controlplane.sh
```

---

## Step 7: Join Worker Nodes

**Run on node01 and node02:**

Use the worker join command from the `kubeadm init` output:

```bash
sudo kubeadm join 10.10.10.10:6443 \
    --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

### Certificates on worker nodes

Workers receive a minimal set of certs:
- **`/etc/kubernetes/kubelet.conf`** — kubeconfig with a client certificate for the kubelet to authenticate to the API server.
- **`/var/lib/kubelet/pki/kubelet-client-current.pem`** — auto-rotated client cert (kubelet handles renewal automatically via the `RotateKubeletClientCertificate` feature).
- **`/var/lib/kubelet/pki/kubelet.crt/.key`** — kubelet's serving cert (for API server -> kubelet communication).

Workers do **not** have the CA private key — they only have `ca.crt` (public) for verification.

**Or use the automation script:**
```bash
./scripts/07-join-workers.sh
```

---

## Step 8: Install Calico CNI

**Run on controlplane1 (or any node with kubectl):**

```bash
# Install the Tigera operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml

# Install Calico custom resources
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml
```

Wait 2-3 minutes for Calico to initialize, then verify:

```bash
# All Calico pods should be Running
kubectl get pods -n calico-system

# To live monitor it
kubectl get pods -n calico-system

# All nodes should now be Ready
kubectl get nodes
```

**Or use the automation script:**
```bash
./scripts/08-install-calico.sh
```

---

## Step 9: Verify the Cluster

```bash
# All 4 nodes should be Ready
kubectl get nodes -o wide

# All system pods running
kubectl get pods -n kube-system
kubectl get pods -n calico-system

# Control plane components (should show 2 of each)
kubectl get pods -n kube-system -l tier=control-plane

# Test a deployment
kubectl create deployment nginx-test --image=nginx --replicas=2
kubectl get pods -o wide
# Pods should schedule on worker nodes (node01, node02)
kubectl delete deployment nginx-test
```

Check HAProxy stats at `http://10.10.10.10:8404/stats` — both backends should show green/UP.

**Or use the automation script:**
```bash
./scripts/09-verify.sh
```

---

## Step 10: Verify Certificates

After the cluster is running, verify the PKI is healthy:

```bash
# Check expiry dates for all certs (run on controlplane1)
sudo kubeadm certs check-expiration
```

Expected output shows all certs, their expiry, and whether they're CA-signed:

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY
admin.conf                 Feb 25, 2027 00:00 UTC   364d            ca
apiserver                  Feb 25, 2027 00:00 UTC   364d            ca
apiserver-etcd-client      Feb 25, 2027 00:00 UTC   364d            etcd-ca
apiserver-kubelet-client   Feb 25, 2027 00:00 UTC   364d            ca
controller-manager.conf    Feb 25, 2027 00:00 UTC   364d            ca
etcd-healthcheck-client    Feb 25, 2027 00:00 UTC   364d            etcd-ca
etcd-peer                  Feb 25, 2027 00:00 UTC   364d            etcd-ca
etcd-server                Feb 25, 2027 00:00 UTC   364d            etcd-ca
front-proxy-client         Feb 25, 2027 00:00 UTC   364d            front-proxy-ca
scheduler.conf             Feb 25, 2027 00:00 UTC   364d            ca

CERTIFICATE AUTHORITY      EXPIRES                  RESIDUAL TIME
ca                         Feb 23, 2036 00:00 UTC   9y
etcd-ca                    Feb 23, 2036 00:00 UTC   9y
front-proxy-ca             Feb 23, 2036 00:00 UTC   9y
```

### Verify API server SANs

Confirm the API server cert includes the load balancer IP:

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Alternative"
```

Should include: `10.10.10.10`, `10.10.10.11`, `10.96.0.1`, `controlplane1`, `kubernetes`, etc.

### Verify CA consistency across control planes

The CA files must be identical on both control planes:

```bash
# Run on controlplane1
sudo sha256sum /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/front-proxy-ca.crt

# Run on controlplane2 and compare hashes — they MUST match
sudo sha256sum /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
```

**Or use the automation script:**
```bash
./scripts/10-setup-certs.sh
```

---

## Certificate Renewal

Kubernetes component certs expire after **1 year**. kubeadm can renew them.

### Automatic renewal during upgrade

When you run `kubeadm upgrade apply`, all certs are renewed automatically.

### Manual renewal

On **each** control plane node:

```bash
# Renew all certs
sudo kubeadm certs renew all

# Restart control plane components to pick up new certs
sudo systemctl restart kubelet

# The static pods (apiserver, controller-manager, scheduler, etcd)
# are restarted automatically by kubelet when their manifests change.
```

### Renew a specific cert

```bash
sudo kubeadm certs renew apiserver
sudo kubeadm certs renew etcd-server
# etc.
```

### Renew the admin.conf kubeconfig

```bash
sudo kubeadm certs renew admin.conf
# Then re-copy it:
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Set up a renewal reminder (cron)

```bash
# Check monthly and alert if any cert expires within 30 days
cat <<'EOF' | sudo tee /etc/cron.monthly/k8s-cert-check
#!/bin/bash
kubeadm certs check-expiration 2>/dev/null | grep -E "^[a-z]" | while read line; do
    days=$(echo "$line" | grep -oP '\d+d' | head -1 | tr -d 'd')
    if [[ -n "$days" && "$days" -lt 30 ]]; then
        echo "WARNING: Kubernetes certificate expiring soon: $line" | logger -t k8s-certs
    fi
done
EOF
sudo chmod +x /etc/cron.monthly/k8s-cert-check
```

### Worker cert rotation

Worker kubelet client certs are rotated **automatically** by the kubelet. Verify:

```bash
# On node01 or node02:
ls -la /var/lib/kubelet/pki/kubelet-client-current.pem
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate
```

---

## Using kubectl From Your Mac

Copy the kubeconfig from controlplane1:

```bash
scp <user>@10.10.10.11:~/.kube/config ~/.kube/config
```

Update the server address to point to the load balancer:

```bash
# Edit ~/.kube/config and change:
#   server: https://10.10.10.11:6443
# to:
#   server: https://10.10.10.10:6443
```

Then:

```bash
kubectl get nodes
```

---

## Automation Scripts

All scripts are in the `scripts/` directory and run **from your Mac** via SSH.

```
scripts/
├── env.sh                      # Configuration (hostnames, IPs, versions)
├── 01-setup-hosts.sh           # /etc/hosts on all 5 nodes
├── 02-setup-firewall.sh        # UFW firewall rules per role
├── 03-setup-haproxy.sh         # HAProxy on loadbalancersrv
├── 04-install-k8s-packages.sh  # kubeadm/kubelet/kubectl
├── 05-init-cluster.sh          # kubeadm init on controlplane1
├── 06-join-controlplane.sh     # Join controlplane2
├── 07-join-workers.sh          # Join node01 + node02
├── 08-install-calico.sh        # Install Calico CNI
├── 09-verify.sh                # Cluster health check
├── 10-setup-certs.sh           # Certificate verification
└── deploy-all.sh               # Master script (runs all 10 steps)
```

1. Edit `scripts/env.sh` — set `SSH_USER` to your SSH username
2. Make scripts executable: `chmod +x scripts/*.sh`
3. Run everything: `./scripts/deploy-all.sh`

Or run individual steps:

```bash
./scripts/deploy-all.sh --from 5    # Resume from step 5 (cluster init)
./scripts/deploy-all.sh --step 2    # Run only step 2 (firewall)
./scripts/deploy-all.sh --step 10   # Run only step 10 (cert check)
```

---

## Troubleshooting

### IP Forwarding Not Enabled

**Symptom:** `kubeadm init` or `kubeadm join` fails with:
```
[ERROR FileContent--proc-sys-net-ipv4-ip_forward]: /proc/sys/net/ipv4/ip_forward contents are not set to 1
```

**Fix:**

```bash
# Enable immediately
sudo sysctl -w net.ipv4.ip_forward=1

# Verify
cat /proc/sys/net/ipv4/ip_forward
# Must return: 1

# Make persistent across reboots
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/k8s.conf
sudo sysctl --system
```

**Root cause:** The sysctl configuration from prerequisites wasn't applied or was overridden. Always verify with `cat /proc/sys/net/ipv4/ip_forward` before running kubeadm.

---

### Swap Not Disabled (kubelet crash-loop)

**Symptom:** `kubeadm join` appears to succeed but components fail to start. Kubelet logs show:
```
"failed to run Kubelet: running with swap on is not supported, please disable swap or set --fail-swap-on flag to false"
```

On control plane joins, this causes the etcd container to never start, producing the misleading error:
```
the etcd member <ID> is not started
```

**Fix:**

```bash
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
free -h   # Verify Swap shows 0B
```

Then reset and retry the join (see "Reset a Node and Retry" below).

**Root cause:** Swap was still active on the joining node. The kubelet refuses to start with swap on, which prevents all pods (including etcd) from running. The error message from kubeadm about etcd is misleading — the real problem is the kubelet.

---

### etcd Member Not Started (Control Plane Join Failure)

**Symptom:** Joining a second (or third) control plane fails with:
```
error execution phase etcd-join: error creating local etcd static pod manifest file: the etcd member <ID> is not started
```

**Root causes (check in this order):**

1. **Swap is enabled** on the joining node (see above — most common cause)
2. **Previous failed join left stale state** — the node wasn't properly cleaned
3. **Stale etcd member** registered on the existing control plane from a previous failed attempt

**Diagnostic steps:**

```bash
# On the JOINING node, check:
free -h                                    # Is swap off?
cat /proc/sys/net/ipv4/ip_forward          # Is it 1?
sudo systemctl status containerd           # Is containerd running?
ls /etc/kubernetes/ 2>&1                   # Should be empty or "No such file"
ls /var/lib/etcd/ 2>&1                     # Should be empty or "No such file"

# On the EXISTING control plane, check for stale members:
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

**Fix — Full cleanup procedure:**

```bash
# --- On the EXISTING control plane (e.g., controlplane1) ---
# Remove the stale etcd member (replace <MEMBER_ID> with actual ID)
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member remove <MEMBER_ID>

# Verify only one member remains
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# --- On the JOINING node (e.g., controlplane2) ---
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d
sudo swapoff -a

# Verify clean state
ls /etc/kubernetes/ 2>&1    # "No such file or directory"
ls /var/lib/etcd/ 2>&1      # "No such file or directory"
free -h                     # Swap = 0

# --- On the EXISTING control plane — regenerate credentials ---
sudo kubeadm init phase upload-certs --upload-certs    # New certificate key
sudo kubeadm token create --print-join-command          # New token + hash

# --- On the JOINING node — retry with fresh credentials ---
sudo kubeadm join 10.10.10.10:6443 \
  --token <NEW_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<NEW_HASH> \
  --control-plane \
  --certificate-key <NEW_CERT_KEY> \
  --apiserver-advertise-address <THIS_NODE_IP>
```

> **Important:** Make sure the `sha256:` hash is on a **single line** with no spaces or line breaks. A broken hash produces: `"invalid discovery token CA certificate hash"`.

---

### Tokens Expired

Join tokens expire after 24 hours. Generate new ones from any control plane:

```bash
# New worker join command
kubeadm token create --print-join-command

# New certificate key for control plane joins (valid for 2 hours)
sudo kubeadm init phase upload-certs --upload-certs
```

---

### Certificate Key Expired

The `--certificate-key` from `kubeadm init` expires after 2 hours. To join a new control plane later:

```bash
# On an existing control plane, re-upload certs:
sudo kubeadm init phase upload-certs --upload-certs
# This prints a new certificate key

# Generate a fresh join token:
sudo kubeadm token create --print-join-command

# Combine them for the new control plane:
sudo kubeadm join 10.10.10.10:6443 \
    --token <new-token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane \
    --certificate-key <new-certificate-key>
```

---

### Node Stuck in NotReady

Usually means Calico isn't running on that node:

```bash
kubectl describe node <node-name>
kubectl get pods -n calico-system -o wide
```

---

### HAProxy Shows Backends DOWN

The API servers haven't started yet, or there's a firewall blocking port 6443:

```bash
# On the control plane, check if apiserver is listening
ss -tlnp | grep 6443

# Check firewall status
sudo ufw status numbered
```

---

### Certificate Errors After Renewal

If you see `x509: certificate has expired` after renewal:

```bash
# Restart kubelet on the affected node
sudo systemctl restart kubelet

# If it's a control plane, the static pods restart automatically.
# If not, manually restart:
sudo crictl pods --name kube-apiserver -q | xargs sudo crictl rmp -f
sudo crictl pods --name kube-controller-manager -q | xargs sudo crictl rmp -f
sudo crictl pods --name kube-scheduler -q | xargs sudo crictl rmp -f
sudo crictl pods --name etcd -q | xargs sudo crictl rmp -f
```

---

### Accidentally Installed K8s Packages on the Load Balancer

If you mistakenly installed kubeadm/kubelet/kubectl/containerd on the load balancer node:

```bash
# Remove Kubernetes packages
sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null
sudo apt-get purge -y kubelet kubeadm kubectl

# Remove containerd (if not needed)
sudo apt-get purge -y containerd containerd.io

# Clean up repos and configs
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni
sudo rm -f /etc/crictl.yaml
sudo rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf

sudo apt-get autoremove -y
```

---

### Reset a Node and Retry

If something goes wrong during join, you must **fully clean up** before retrying:

```bash
# Reset kubeadm state
sudo kubeadm reset -f

# Remove ALL leftover directories
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet
sudo rm -rf /etc/cni/net.d
sudo rm -rf $HOME/.kube

# Verify clean state
ls /etc/kubernetes/ 2>&1    # "No such file or directory"
ls /var/lib/etcd/ 2>&1      # "No such file or directory"
```

> **Warning:** Do NOT flush iptables (`iptables -F`) on a remote node — this will kill your SSH session because UFW rules depend on iptables. Only clean iptables if you have physical/console access.

> **Note:** If this was a control plane join failure, you must also remove the stale etcd member from the existing control plane (see "etcd Member Not Started" above) before retrying.
