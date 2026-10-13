# Prerequisites:
1. A valid Solo.io license key, exported as `$SOLO_TRIAL_LICENSE_KEY`
2. solo-istioctl installed ([Solo istioCTL installation](000-tools.md#solos-istioctl-binary))
3. helm installed
4. A kubernetes version >1.29
5. `openssl` available in your shell. Lab `002` uses it to generate the shared root trust CA. macOS and Linux include it by default. Windows users must use WSL or Git Bash.
6. Vegeta for load generation ([Vegeta installation](000-tools.md#vegeta-cli-load-generator)). Labs `011` and `017` use it
7. `curl` with HTTPS support and `openssl` on your shell host (lab `013` verifies certificates with both)
8. Access to `github.com` release downloads (lab `016` downloads the `ingress2gateway` binary)
9. Two more Kubernetes clusters, `cluster3` and `cluster4` (lab `018` only)

> **Network:** the clusters peer over NodePorts. The nodes of each cluster must reach the node InternalIPs of every other cluster on the NodePort range (default `30000-32767`), for the two NodePorts that map to **15008** (HBONE data plane) and **15012** (xDS/CA and registry sync) on the east-west gateway. Full list: [Ports used in an Istio ambient mesh](../reference/ambient-ports.md).

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

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/gateway --version 1.28.10-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel --version 1.28.10-patch0-solo
```

Upgrade target for lab `017`
```bash
helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/base --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/cni --version 1.29.7-patch0-solo

helm pull oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel --version 1.29.7-patch0-solo
```

cert-manager Helm chart (lab `013`)
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

**Istio Upgrade Images (lab `017`):**
```bash
docker pull us-docker.pkg.dev/soloio-img/istio/install-cni:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/pilot:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/proxyv2:1.29.7-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/ztunnel:1.29.7-patch0-solo-distroless
```

**Book Info Images:**
```bash
docker pull docker.io/istio/examples-bookinfo-details-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-ratings-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v2:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v3:1.20.2
```

**Test Client Images (labs `007`, `008`, `014`, `015`, `018`):**
```bash
docker pull curlimages/curl:8.22.0
```

**Load Test Images (lab `009`):**
```bash
docker pull fortio/fortio:1.75.3
```

**Echo App Images (labs `014`, `015`, `016`):**
```bash
docker pull docker.io/istio/app:1.28.10
```

**Observability Images (lab `010`):**
```bash
docker pull prom/prometheus:v3.15.0
docker pull grafana/grafana:13.0.8
```

**cert-manager Images (lab `013`):**
```bash
docker pull quay.io/jetstack/cert-manager-controller:v1.21.2
docker pull quay.io/jetstack/cert-manager-webhook:v1.21.2
docker pull quay.io/jetstack/cert-manager-cainjector:v1.21.2
docker pull quay.io/jetstack/cert-manager-startupapicheck:v1.21.2
```

**Load Balancer Images (lab `014`):**
```bash
docker pull haproxy:3.2.23-alpine
```
