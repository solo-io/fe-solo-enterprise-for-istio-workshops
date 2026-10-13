# Solo Enterprise for Istio Workshops

Hands-on workshops for deploying and operating **Solo Enterprise for Istio** with Ambient Mesh. Workshops cover zero-trust security, ingress, egress control, observability, multi-cluster routing, and global service discovery using the Bookinfo sample application.

![](/images/intro-1.png)

## Workshops

| Workshop | Platform | Clusters | Description |
|---|---|---|---|
| [`istio-ambient-single-cluster`](istio-ambient-single-cluster/) | Standard Kubernetes | 1 | Single-cluster ambient mesh on standard Kubernetes — zero trust, ingress, egress, waypoints, observability, Solo Management UI, gRPC load balancing, VM integration. |
| [`istio-ambient-single-cluster-on-openshift`](istio-ambient-single-cluster-on-openshift/) | OpenShift | 1 | Single-cluster ambient mesh on OpenShift — ingress, egress, waypoints, observability with OpenShift User Workload Monitoring, Solo Management UI. |
| [`istio-ambient-multicluster-on-openshift`](istio-ambient-multicluster-on-openshift/) | OpenShift | 2 | Ambient mesh across two OpenShift clusters — multicluster routing, global service discovery, failover, segments, global aliases, zero-trust access control, egress, waypoints, observability, Solo Management UI. |
| [`istio-ambient-multicluster`](istio-ambient-multicluster/) | Standard Kubernetes | 2 | Ambient mesh across two standard Kubernetes clusters — multicluster routing, global service discovery, failover, segments, global aliases, zero-trust access control, egress, waypoints, observability, Solo Management UI, cross-cluster gRPC load balancing, service migration between clusters with service takeover. |
| [`istio-ambient-multicluster-nodeport`](istio-ambient-multicluster-nodeport/) | Standard Kubernetes | 2 (4 in lab `018`) | Ambient mesh across two standard Kubernetes clusters peered through NodePort east-west gateways with no LoadBalancer, following Solo's NodePort reference architecture. Multicluster routing, global service discovery, failover, zero trust with workload quarantine, waypoints, east-west data path measurement, metrics federation, hostname migration between clusters, peering lifecycle, cert-manager certificates, client source IP, egress with stable IPs, ingress-nginx migration, upgrade and rollback, and adding two clusters for a four-cluster mesh. |
| [`istio-oss-sidecar-to-enterprise-ambient`](istio-oss-sidecar-to-enterprise-ambient/) | Standard Kubernetes | 1 | In-place migration from OSS Istio sidecar to Solo Enterprise Ambient, ingress, egress, waypoints, observability, zero-trust access control |

## Reference

| Page | Description |
|---|---|
| [`style-guide.md`](style-guide.md) | Conventions for writing new labs: skeleton, command idioms, verification, cleanup, and the maintenance checklist. |
| [`reference/ambient-ports.md`](reference/ambient-ports.md) | Every port an ambient mesh uses, grouped by data plane, telemetry, and control plane. The list to hand to whoever owns your firewalls, security groups, and `NetworkPolicy`. |

## Use Cases Covered

| Use Case | Single-cluster (K8s) | Single-cluster OSS→Ambient (K8s) | Multicluster (K8s) | Multicluster NodePort (K8s) | Single-cluster (OCP) | Multicluster (OCP) |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Sidecars | | ✓ | | | | |
| Migration | | ✓ | | | | |
| Zero Trust (mTLS) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ingress | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Egress Control | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Waypoints | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| gRPC load balancing | ✓ | | ✓ | | | |
| VM integration | ✓ | | | | | |
| Observability | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Multi-cluster routing | | | ✓ | ✓ | | ✓ |
| Global service discovery | | | ✓ | ✓ | | ✓ |
| High Availability / Failover | | | ✓ | ✓ | | ✓ |
| Multitenancy (segments) | | | ✓ | | | ✓ |
| Global Aliases | | | ✓ | | | ✓ |
| Service migration between clusters (service takeover) | | | ✓ | | | |
| Solo Management UI | ✓ | | ✓ | | ✓ | ✓ |
| Workload quarantine | | | | ✓ | | |
| East-west data path and gateway bypass | | | | ✓ | | |
| Metrics federation across clusters | | | | ✓ | | |
| Hostname migration between clusters | | | | ✓ | | |
| Peering lifecycle (drift, NodePort pinning, unpeer and re-peer) | | | | ✓ | | |
| TLS certificates with cert-manager | | | | ✓ | | |
| Client source IP (PROXY protocol, `externalTrafficPolicy`) | | | | ✓ | | |
| Ingress migration from ingress-nginx | | | | ✓ | | |
| Upgrade and rollback | | | | ✓ | | |
| Add clusters past two (full-mesh peering) | | | ✓ | ✓ | | |

## Versions

| Component | Version |
|---|---|
| Istio (Solo) | 1.30.5-solo |
| Solo Management UI | 0.5.8 |
| Kubernetes | ≥ 1.29 |
| OpenShift | 4.16.0 – 4.19.x |

The `istio-ambient-multicluster-nodeport` workshop runs on Istio `1.28.10-patch0-solo`, and lab `017` upgrades it to `1.29.7-patch0-solo` and back.

## Prerequisites

- A valid Solo.io license key
- `solo-istioctl` ([install guide](istio-ambient-single-cluster-on-openshift/000-tools.md))
- `helm`
- One or two clusters depending on the workshop (see table above)

## Getting Started

1. Clone this repo
2. Obtain a Solo.io trial license key
3. Choose a workshop from the table above
4. Follow the labs in order starting with `000-introduction.md`
