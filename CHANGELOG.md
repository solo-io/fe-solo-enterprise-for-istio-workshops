# Changelog

0.0.5 - (10-14-26)
---
- Switch `istio-ambient-multicluster-nodeport` peering to Solo's `peering` Helm chart `1.29.7-patch0-solo` with its NodePort data plane (beta), on Istio `1.28.10-patch0-solo`
- Update `istio-ambient-multicluster-nodeport` `README.md`, `000-introduction.md`, `000-prerequisites.md` (peering chart, fixed NodePorts) and `000-tools.md`, and the root `README.md`

0.0.4 - (10-13-26)
---
- Add `istio-ambient-multicluster-nodeport/005-install-agentgateway-as-an-ingress-gw.md`: install Solo Enterprise for agentgateway `v2026.9.3` on cluster1 with its Istio integration 
- Update `istio-ambient-multicluster-nodeport` to use agentgateway as the ingress gateway in every lab
- Move labs `005`-`019` to `006`-`020` in `istio-ambient-multicluster-nodeport`, with every lab-number reference and asset comment updated
- Add `images/expose-bookinfo-agentgateway-1.png` and `images/multicluster-global-mesh-agentgateway-1.png`
- Update `istio-ambient-multicluster-nodeport` `README.md`, `000-introduction.md`, `000-tools.md` (lab numbers) and `000-prerequisites.md`

0.0.3 - (10-13-26)
---
- Add 12 labs to `istio-ambient-multicluster-nodeport`, each validated on vind with Istio `1.28.10-patch0-solo`:
  - `007-mesh-access-control.md`: deny-all baseline with explicit per-cluster trust domains, `STRICT` mTLS, pod and identity quarantine, and how a one-cluster quarantine leaks through global-service failover
  - `008-waypoints.md`: waypoints and their policies in both clusters, GET-only L7 policy, weighted and header routing, faults, and retries against a broken replica
  - `009-east-west-data-path.md`: trace and measure five east-west paths with fortio, send a central-gateway hostname to in-mesh pods with a `ServiceEntry`, and list where the bypass does not apply
  - `010-observability.md`: central Prometheus and Grafana in cluster1, agent-mode Prometheus in cluster2 writing over the mesh, scrape keep-list, namespace dashboard
  - `011-move-a-hostname-between-clusters.md`: move a stable hostname from cluster1 to cluster2 by route weight under load
  - `012-nodeport-peering-lifecycle.md`: peer drift check, delayed failure after a NodePort change, repair, NodePort pinning, unpeer and re-peer for any number of clusters
  - `013-per-hostname-certificates.md`: cert-manager `v1.21.2` with Gateway API support, ECDSA P-256 certificate per listener hostname, rotation without a restart
  - `014-client-source-ip.md`: `externalTrafficPolicy` `Cluster` vs `Local`, PROXY protocol v2 through haproxy, `X-Forwarded-For` across clusters, access log
  - `015-egress-with-stable-ips.md`: egress waypoint pinned to labelled egress nodes, `ServiceEntry` and egress `AuthorizationPolicy`, closing the direct path
  - `016-migrate-ingress-nginx.md`: `ingress2gateway` `v1.2.0` for ingress-nginx and Istio ingress objects, review findings, capture-group rewrites, gRPC with mesh mTLS, per-team cutover, CI gate
  - `017-upgrade-and-roll-back.md`: in-place Helm upgrade from `1.28.10-patch0-solo` to `1.29.7-patch0-solo` under load, cluster by cluster, and rollback
  - `018-add-clusters.md`: add `cluster3` and `cluster4`, pin their east-west NodePorts before the first peering, check NodePort reachability in all twelve directions, peer the four clusters with one loop, extend the identity policies to the new trust domains, four-way failover, drift check for every pair
- Add workshop assets: `auth-policy/`, `perf/`, `observability/` (Prometheus, agent, Grafana, dashboard JSON), `ingress-nginx/`, and `images`
- Update root `README.md` (workshop description, use-case matrix, versions note)
- Update `.gitignore`

0.0.2 - (10-12-26)
---
- Add `style-guide.md`: lab authoring conventions audited from the full workshop corpus (skeleton, command idioms, verification, cleanup, sibling-workshop sync, repo maintenance checklist)
- Add `istio-ambient-multicluster-nodeport` workshop: peers two clusters through NodePort east-west gateways with no LoadBalancer, following Solo's multi-cluster NodePort reference architecture
- Update `README.md` (workshop row, `Multicluster NodePort (K8s)` use-case column, versions note)

0.0.1 - (10-6-26)
---
- Bump Solo Istio from `1.30.2-solo` to `1.30.5-solo` across all workshops (Helm charts, `-solo-distroless` images, `ISTIO_VERSION` exports, version tables)
- Bump `docker.io/istio/app` from `1.30.2` to `1.30.5` and drop the `@sha256` digest pin from the gRPC manifests
- Add `lib/mirror-images.sh` to copy each workshop's prerequisite images (all architectures) to a private registry for air-gapped runs

0.0.0 - (10-5-26)
---
- Move resources from personal `ably77/solo-enterprise-for-istio-workshops` github repo to `solo-io/fe-solo-enterprise-for-istio-workshops`