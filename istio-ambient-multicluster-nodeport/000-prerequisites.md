# Prerequisites:
1. A valid Solo.io license key, exported as `$SOLO_TRIAL_LICENSE_KEY`
2. solo-istioctl installed ([Solo istioCTL installation](000-tools.md#solos-istioctl-binary))
3. helm installed
4. A kubernetes version >1.29
5. `openssl` available in your shell. Lab `002` uses it to generate the shared root trust CA. macOS and Linux include it by default. Windows users must use WSL or Git Bash.
6. Vegeta for load generation ([Vegeta installation](000-tools.md#vegeta-cli-load-generator)). Labs `012` and `018` use it
7. `curl` with HTTPS support and `openssl` on your shell host (lab `014` verifies certificates with both)
8. Access to `github.com` release downloads (lab `017` downloads the `ingress2gateway` binary)
9. Two more Kubernetes clusters, `cluster3` and `cluster4` (lab `019` only)

> **Network:** the clusters peer over NodePorts. Lab `007` fixes the east-west NodePorts at `31508` for **15008** (HBONE data plane) and `31512` for **15012** (xDS/CA and registry sync). The nodes of each cluster must reach every node InternalIP of the other clusters on `31508`, and the peer node that lab `007` selects for xDS on `31512`. Full list: [Ports used in an Istio ambient mesh](../reference/ambient-ports.md).

### Repos/Images:

> **Air-gapped clusters:** [`lib/mirror-images.sh`](../lib/mirror-images.sh) copies every image listed below, with all
> architectures, to your registry as `<registry>/<name>:<tag>`. Run it from the repo root. It is a dry run until you add `--push`:
> `lib/mirror-images.sh <registry> istio-ambient-multicluster-nodeport --push`.
> Point Istio at the mirror with `global.hub=<registry>`.

**Helm Repos**

Solo Istio Helm Charts
```bash
helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/base --version 1.28.10-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod --version 1.28.10-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/cni --version 1.28.10-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel --version 1.28.10-patch0-solo
```

Solo peering Helm chart (labs `007`, `013`, `019`)
```bash
helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/peering --version 1.29.7-patch0-solo
```

Upgrade target for lab `018`
```bash
helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/base --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/cni --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel --version 1.29.7-patch0-solo
```

Solo Enterprise for agentgateway Helm charts (lab `005`)
```bash
helm pull oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds --version v2026.9.3

helm pull oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway --version v2026.9.3
```

cert-manager Helm chart (lab `014`)
```bash
helm pull oci://quay.io/jetstack/charts/cert-manager --version v1.21.2
```

**Istio Images:**
```bash
docker pull us-docker.pkg.dev/soloio-img/istio/install-cni:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/pilot:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/proxyv2:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/ztunnel:1.28.10-patch0-solo-distroless
```

**Istio Upgrade Images (lab `018`):**
```bash
docker pull us-docker.pkg.dev/soloio-img/istio/install-cni:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/pilot:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/proxyv2:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/ztunnel:1.29.7-patch0-solo-distroless
```

**Agentgateway Images (lab `005`):**
```bash
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/enterprise-agentgateway-controller:2026.9.3
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise:2026.9.3
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/redis:8.6.7-alpine
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/ext-auth-service:2026.9.3
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/rate-limiter:2026.9.3
docker pull us-docker.pkg.dev/solo-public/enterprise-agentgateway/waf-server:2026.9.3
```

**Book Info Images:**
```bash
docker pull docker.io/istio/examples-bookinfo-details-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-ratings-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v2:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v3:1.20.2
```

**Test Client Images (labs `008`, `009`, `015`, `016`, `019`):**
```bash
docker pull curlimages/curl:8.22.0
```

**Load Test Images (lab `010`):**
```bash
docker pull fortio/fortio:1.75.3
```

**Echo App Images (labs `015`, `016`, `017`):**
```bash
docker pull docker.io/istio/app:1.28.10
```

**Observability Images (lab `011`):**
```bash
docker pull prom/prometheus:v3.15.0
docker pull grafana/grafana:13.0.8
```

**cert-manager Images (lab `014`):**
```bash
docker pull quay.io/jetstack/cert-manager-controller:v1.21.2
docker pull quay.io/jetstack/cert-manager-webhook:v1.21.2
docker pull quay.io/jetstack/cert-manager-cainjector:v1.21.2
docker pull quay.io/jetstack/cert-manager-startupapicheck:v1.21.2
```

**Load Balancer Images (lab `015`):**
```bash
docker pull haproxy:3.2.23-alpine
```
