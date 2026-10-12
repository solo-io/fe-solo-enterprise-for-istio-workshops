# Prerequisites:
1. A valid Solo.io license key, exported as `$SOLO_TRIAL_LICENSE_KEY`
2. solo-istioctl installed ([Solo istioCTL installation](000-tools.md#solos-istioctl-binary))
3. helm installed
4. A kubernetes version >1.29
5. `openssl` available in your shell. Lab `002` uses it to generate the shared root trust CA. macOS and Linux include it by default. Windows users must use WSL or Git Bash.
6. If you want to push local traffic easily install Vegeta as well ([Vegeta installation](000-tools.md#vegeta-cli-load-generator))

> **Network:** the clusters peer over NodePorts. The nodes of each cluster must reach the node InternalIPs of the other cluster on the NodePort range (default `30000-32767`), for the two NodePorts that map to **15008** (HBONE data plane) and **15012** (xDS/CA and registry sync) on the east-west gateway. Full list: [Ports used in an Istio ambient mesh](../reference/ambient-ports.md).

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

**Istio Images:**
```bash
docker pull us-docker.pkg.dev/soloio-img/istio/install-cni:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/pilot:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/proxyv2:1.28.10-patch0-solo-distroless
docker pull us-docker.pkg.dev/soloio-img/istio/ztunnel:1.28.10-patch0-solo-distroless
```

**Book Info Images:**
```bash
docker pull docker.io/istio/examples-bookinfo-details-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-ratings-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v1:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v2:1.20.2
docker pull docker.io/istio/examples-bookinfo-reviews-v3:1.20.2
```
