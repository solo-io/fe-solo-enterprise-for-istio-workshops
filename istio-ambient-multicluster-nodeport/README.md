# Istio Ambient Multicluster NodePort Workshop: Kubernetes

Hands-on workshop for deploying Solo Enterprise for Istio Ambient Mesh across two Kubernetes clusters peered through NodePort east-west gateways, with Solo Enterprise for agentgateway as the ingress gateway. It uses the Bookinfo sample application.

## Versions

| Component | Version |
|---|---|
| Istio (Solo) | 1.28.10-patch0-solo (lab `018` upgrades to 1.29.7-patch0-solo and back) |
| Solo Enterprise for agentgateway | v2026.9.3 |
| Gateway API | v1.4.1 |
| Kubernetes | ≥ 1.29 |

## Prerequisites

- A valid Solo.io license key
- `solo-istioctl`: see [000-tools.md](000-tools.md)
- `helm`
- Two Kubernetes clusters (≥ 1.29) whose nodes can reach each other's InternalIPs on the NodePort range
- Two more clusters for lab `019`, reachable the same way
- Vegeta for load generation (labs `012` and `018`): see [000-tools.md](000-tools.md)
- `openssl` (labs `002` and `014`)

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
| [005-install-agentgateway-as-an-ingress-gw.md](005-install-agentgateway-as-an-ingress-gw.md) | Install agentgateway as the ingress gateway, integrated with the ambient mesh |
| [006-expose-bookinfo.md](006-expose-bookinfo.md) | Expose Bookinfo through agentgateway |
| [007-multicluster-global-mesh.md](007-multicluster-global-mesh.md) | Peer the clusters over NodePort and configure failover |
| [008-mesh-access-control.md](008-mesh-access-control.md) | Zero trust across clusters, `STRICT` mTLS, and quarantining a pod or an identity |
| [009-waypoints.md](009-waypoints.md) | L7 policy, traffic shifting, faults and retries with waypoints in both clusters |
| [010-east-west-data-path.md](010-east-west-data-path.md) | Trace and measure each east-west path, bypass a central gateway hostname, and the bypass boundaries |
| [011-observability.md](011-observability.md) | Lean metrics: central Prometheus, agent-mode Prometheus over the mesh, namespace dashboards |
| [012-move-a-hostname-between-clusters.md](012-move-a-hostname-between-clusters.md) | Move a stable customer hostname between clusters by route weight, under load |
| [013-nodeport-peering-lifecycle.md](013-nodeport-peering-lifecycle.md) | Detect and repair peering drift, pin NodePorts, take a cluster out and bring it back |
| [014-per-hostname-certificates.md](014-per-hostname-certificates.md) | Per-hostname ECDSA P-256 certificates from cert-manager on the ingress gateway |
| [015-client-source-ip.md](015-client-source-ip.md) | Keep the real client IP: `externalTrafficPolicy`, PROXY protocol, `X-Forwarded-For` across clusters |
| [016-egress-with-stable-ips.md](016-egress-with-stable-ips.md) | Egress through a waypoint pinned to egress nodes, with stable source IPs and egress policy |
| [017-migrate-ingress-nginx.md](017-migrate-ingress-nginx.md) | Convert ingress-nginx and Istio ingress objects to Gateway API for agentgateway with `ingress2gateway`, including capture-group rewrites |
| [018-upgrade-and-roll-back.md](018-upgrade-and-roll-back.md) | In-place upgrade from 1.28 to 1.29 under load, and roll back |
| [019-add-clusters.md](019-add-clusters.md) | Add two clusters and peer all four over NodePort: pinned ports, reachability matrix, trust domains, four-way failover |
| [020-cleanup.md](020-cleanup.md) | Teardown |

## Getting Started

Every lab runs its commands relative to this directory (`kubectl apply -f bookinfo/...`, `./solo-istioctl`), so change into it first:

```bash
cd istio-ambient-multicluster-nodeport
```

Then work through the labs in order, starting with [000-introduction.md](000-introduction.md).

## Reference

- [Ports used in an Istio ambient mesh](../reference/ambient-ports.md): what to open on firewalls, cloud security groups, and `NetworkPolicy`.
