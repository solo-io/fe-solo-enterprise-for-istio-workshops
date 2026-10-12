# Istio Ambient Multicluster NodePort Workshop: Kubernetes

Hands-on workshop for deploying Solo Enterprise for Istio Ambient Mesh across two Kubernetes clusters peered through NodePort east-west gateways. It uses the Bookinfo sample application.

## Versions

| Component | Version |
|---|---|
| Istio (Solo) | 1.28.10-patch0-solo |
| Kubernetes | ≥ 1.29 |

## Prerequisites

- A valid Solo.io license key
- `solo-istioctl`: see [000-tools.md](000-tools.md)
- `helm`
- Two Kubernetes clusters (≥ 1.29) whose nodes can reach each other's InternalIPs on the NodePort range
- (Optional) Vegeta for load generation: see [000-tools.md](000-tools.md)

## Labs

| Lab | Topic |
|---|---|
| [000-introduction.md](000-introduction.md) | Overview and objectives |
| [000-prerequisites.md](000-prerequisites.md) | Requirements and image list |
| [000-tools.md](000-tools.md) | Tool installation |
| [001-deploy-bookinfo.md](001-deploy-bookinfo.md) | Deploy the Bookinfo application |
| [002-install-istio-on-cluster1.md](002-install-istio-on-cluster1.md) | Install Istio Ambient on cluster1 |
| [003-install-istio-on-cluster2.md](003-install-istio-on-cluster2.md) | Install Istio Ambient on cluster2 |
| [004-enroll-apps-in-the-mesh.md](004-enroll-apps-in-the-mesh.md) | Enroll workloads in the mesh |
| [005-expose-bookinfo.md](005-expose-bookinfo.md) | Configure the ingress gateway |
| [006-multicluster-global-mesh.md](006-multicluster-global-mesh.md) | Peer the clusters over NodePort and configure failover |
| [007-cleanup.md](007-cleanup.md) | Teardown |

## Getting Started

Every lab runs its commands relative to this directory (`kubectl apply -f bookinfo/...`, `./solo-istioctl`), so change into it first:

```bash
cd istio-ambient-multicluster-nodeport
```

Then work through the labs in order, starting with [000-introduction.md](000-introduction.md).

## Reference

- [Ports used in an Istio ambient mesh](../reference/ambient-ports.md): what to open on firewalls, cloud security groups, and `NetworkPolicy`.
