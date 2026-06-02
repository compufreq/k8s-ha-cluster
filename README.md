# k8s-ha-cluster

Production-style **high-availability Kubernetes cluster** built from scratch with `kubeadm` — two stacked control planes behind an HAProxy load balancer, Calico CNI, and a full set of idempotent automation scripts you run over SSH. Includes a deep dive into the cluster PKI, certificate lifecycle, and the failure modes you actually hit when bootstrapping HA.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35-326CE5?logo=kubernetes&logoColor=white)
![CNI: Calico](https://img.shields.io/badge/CNI-Calico-FF6D70)
![Runtime: containerd](https://img.shields.io/badge/runtime-containerd-575757)

> Originally part of [cka-mindmap](https://github.com/compufreq/cka-mindmap); split into its own repo because the HA build stands on its own as a reference and a CKA/CKS study lab.

---

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
| --------------- | ----------- | --------------------- |
| loadbalancersrv | 10.10.10.10 | HAProxy load balancer |
| controlplane1   | 10.10.10.11 | Control Plane 1       |
| controlplane2   | 10.10.10.12 | Control Plane 2       |
| node01          | 10.10.10.14 | Worker 1              |
| node02          | 10.10.10.15 | Worker 2              |

- **Load balancer:** HAProxy on `loadbalancersrv`, round-robins API traffic (`:6443`) across both control planes; stats dashboard on `:8404`.
- **Control planes:** stacked etcd topology — each runs `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`.
- **Workers:** run application workloads.
- **CNI:** Calico (pod CIDR `192.168.0.0/16`).
- **Runtime:** containerd with `SystemdCgroup`.
- **Kubernetes:** v1.35.

---

## What this repo covers

- Bringing up a **true HA control plane** (2 control planes + LB) — not a single-node toy cluster.
- The complete **cluster PKI**: what `kubeadm init` generates under `/etc/kubernetes/pki/`, how `--upload-certs` and the certificate key let a second control plane join, and which certs are shared vs. regenerated per node.
- **Certificate lifecycle**: expiry, manual and upgrade-driven renewal, kubelet client-cert auto-rotation, and a monthly cron expiry check.
- **Firewall design** (UFW) with the exact ports each role needs, including Calico BGP/VXLAN/Typha.
- A real **troubleshooting playbook** for the failures that actually break HA joins (swap left on, missing IP forwarding, stale etcd members, expired tokens/cert keys, NotReady nodes, HAProxy backends down).

---

## Repository layout

```
.
├── guide.md            # Full step-by-step walkthrough (start here for the deep detail)
├── LICENSE             # MIT
├── README.md
└── scripts/
    ├── env.sh                      # Configuration: hostnames, IPs, versions, SSH user
    ├── 01-setup-hosts.sh           # /etc/hosts on all 5 nodes
    ├── 02-setup-firewall.sh        # UFW rules per role
    ├── 03-setup-haproxy.sh         # HAProxy on the load balancer
    ├── 04-install-k8s-packages.sh  # kubeadm / kubelet / kubectl
    ├── 05-init-cluster.sh          # kubeadm init on controlplane1
    ├── 06-join-controlplane.sh     # Join controlplane2
    ├── 07-join-workers.sh          # Join node01 + node02
    ├── 08-install-calico.sh        # Install Calico CNI
    ├── 09-verify.sh                # Cluster health checks
    ├── 10-setup-certs.sh           # Certificate verification
    └── deploy-all.sh               # Orchestrates all 10 steps
```

---

## Prerequisites

- **5 Linux hosts** (Ubuntu tested) — VMs or bare metal — reachable on a shared network, matching the IP plan above (edit `scripts/env.sh` to use your own).
- SSH access to all five from your workstation, with a user that can `sudo`.
- On **all Kubernetes nodes** (not the LB), the scripts handle: disabling swap, loading `overlay` + `br_netfilter`, enabling IP forwarding, installing/configuring containerd, and installing `crictl`. See [`guide.md`](guide.md#prerequisites) for what each step does and why.

---

## Quick start (automated)

```bash
# 1. Clone
git clone https://github.com/compufreq/k8s-ha-cluster.git
cd k8s-ha-cluster

# 2. Set your SSH user, hostnames, IPs, and versions
$EDITOR scripts/env.sh

# 3. Make scripts executable
chmod +x scripts/*.sh

# 4. Run the whole build from your workstation (over SSH)
./scripts/deploy-all.sh
```

Run individual phases instead:

```bash
./scripts/deploy-all.sh --from 5     # Resume from step 5 (cluster init)
./scripts/deploy-all.sh --step 2     # Run only step 2 (firewall)
./scripts/deploy-all.sh --step 10    # Run only cert verification
```

## Manual / learning path

If you'd rather understand each phase, follow [`guide.md`](guide.md) top to bottom — it walks through the same ten steps by hand with full explanations, expected output, and the certificate internals at each join.

---

## Verifying the cluster

```bash
kubectl get nodes -o wide          # all 4 nodes Ready
kubectl get pods -n kube-system    # control-plane components (2 of each)
kubectl get pods -n calico-system  # Calico Running
sudo kubeadm certs check-expiration
```

HAProxy stats: open `http://10.10.10.10:8404/stats` — both control-plane backends should be **UP**.

---

## Troubleshooting

`guide.md` includes fixes for the common HA bootstrap failures:

- `ip_forward` not set to 1 (preflight error)
- swap left enabled → kubelet crash-loop → misleading "etcd member not started"
- stale etcd member after a failed control-plane join (full cleanup procedure)
- expired join tokens (24h) and certificate keys (2h)
- nodes stuck `NotReady` (Calico), HAProxy backends `DOWN`, post-renewal cert errors

See [Troubleshooting](guide.md#troubleshooting).

---

## Why I built this

Hands-on practice for the **CNCF certification track** (CKA / CKS) and a reference for standing up HA Kubernetes the hard way — kubeadm, stacked etcd, and a load balancer — so the cert lifecycle and join mechanics aren't a black box. Part of my broader [platform/SRE portfolio](https://github.com/compufreq).

---

## License

Released under the [MIT License](LICENSE). © 2026 Alaa Alhorani.