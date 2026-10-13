# Istio Ambient Multicluster NodePort Workshop: Kubernetes

Hands-on workshop for deploying Solo Enterprise for Istio Ambient Mesh across two Kubernetes clusters peered through NodePort east-west gateways. It uses the Bookinfo sample application.

## Versions

| Component | Version |
|---|---|
| Istio (Solo) | 1.28.10-patch0-solo (lab `017` upgrades to 1.29.7-patch0-solo and back) |
| Kubernetes | ≥ 1.29 |

## Prerequisites

- A valid Solo.io license key
- `solo-istioctl`: see [000-tools.md](000-tools.md)
- `helm`
- Two Kubernetes clusters (≥ 1.29) whose nodes can reach each other's InternalIPs on the NodePort range
- Two more clusters for lab `018`, reachable the same way
- Vegeta for load generation (labs `011` and `017`): see [000-tools.md](000-tools.md)
- `openssl` (labs `002` and `013`)

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
| [007-mesh-access-control.md](007-mesh-access-control.md) | Zero trust across clusters, `STRICT` mTLS, and quarantining a pod or an identity |
| [008-waypoints.md](008-waypoints.md) | L7 policy, traffic shifting, faults and retries with waypoints in both clusters |
| [009-east-west-data-path.md](009-east-west-data-path.md) | Trace and measure each east-west path, bypass a central gateway hostname, and the bypass boundaries |
| [010-observability.md](010-observability.md) | Lean metrics: central Prometheus, agent-mode Prometheus over the mesh, namespace dashboards |
| [011-move-a-hostname-between-clusters.md](011-move-a-hostname-between-clusters.md) | Move a stable customer hostname between clusters by route weight, under load |
| [012-nodeport-peering-lifecycle.md](012-nodeport-peering-lifecycle.md) | Detect and repair peering drift, pin NodePorts, take a cluster out and bring it back |
| [013-per-hostname-certificates.md](013-per-hostname-certificates.md) | Per-hostname ECDSA P-256 certificates from cert-manager on the ingress gateway |
| [014-client-source-ip.md](014-client-source-ip.md) | Keep the real client IP: `externalTrafficPolicy`, PROXY protocol, `X-Forwarded-For` across clusters |
| [015-egress-with-stable-ips.md](015-egress-with-stable-ips.md) | Egress through a waypoint pinned to egress nodes, with stable source IPs and egress policy |
| [016-migrate-ingress-nginx.md](016-migrate-ingress-nginx.md) | Convert ingress-nginx and Istio ingress objects to Gateway API with `ingress2gateway` |
| [017-upgrade-and-roll-back.md](017-upgrade-and-roll-back.md) | In-place upgrade from 1.28 to 1.29 under load, and roll back |
| [018-add-clusters.md](018-add-clusters.md) | Add two clusters and peer all four over NodePort: pinned ports, reachability matrix, trust domains, four-way failover |
| [019-cleanup.md](019-cleanup.md) | Teardown |

## Getting Started

Every lab runs its commands relative to this directory (`kubectl apply -f bookinfo/...`, `./solo-istioctl`), so change into it first:

```bash
cd istio-ambient-multicluster-nodeport
```

Then work through the labs in order, starting with [000-introduction.md](000-introduction.md).

## Reference

- [Ports used in an Istio ambient mesh](../reference/ambient-ports.md): what to open on firewalls, cloud security groups, and `NetworkPolicy`.
