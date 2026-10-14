# Prerequisites:
1. A valid Solo.io license key, exported as `$SOLO_TRIAL_LICENSE_KEY`
2. solo-istioctl installed ([Solo istioCTL installation](000-tools.md#solos-istioctl-binary))
3. helm installed
4. Kubernetes 1.29 or later
5. `openssl` available in your shell. Lab `002` uses it to generate the shared root trust CA. macOS and Linux include it by default. Windows users must use WSL or Git Bash.
6. Vegeta for load generation ([Vegeta installation](000-tools.md#vegeta-cli-load-generator)). Labs `012` and `018` use it
7. `curl` with HTTPS support (lab `014` verifies certificates with `curl` and `openssl`)
8. Access to `github.com` release downloads (lab `017` downloads the `ingress2gateway` binary)
9. Two more Kubernetes clusters, `cluster3` and `cluster4` (lab `019` only)

> **Network:** the clusters peer over NodePorts. Lab `007` fixes the east-west NodePorts at `31508` for **15008** (HBONE data plane) and `31512` for **15012** (xDS/CA and registry sync). The nodes of each cluster must reach every node InternalIP of the other clusters on `31508`, and the peer node that lab `007` selects for xDS on `31512`. Full list: [Ports used in an Istio ambient mesh](../reference/ambient-ports.md).

> **Cilium with kube-proxy replacement (KPR):** Istio ambient runs on top of Cilium as the CNI, with or without kube-proxy. Set these Cilium Helm values in every cluster before lab `002`:
> ```yaml
> kubeProxyReplacement: true
> k8sServiceHost: <api-server-host>   # Cilium reaches the API server directly without kube-proxy
> k8sServicePort: 6443
> cni:
>   exclusive: false          # keeps the istio-cni plugin in Cilium's chained CNI config
> socketLB:
>   hostNamespaceOnly: true   # pods keep the Service IP, so ztunnel picks the endpoint
> bpf:
>   masquerade: false         # the default. eBPF masquerading breaks ambient health probes
> ```
> Check the running config in each cluster:
> ```bash
> kubectl -n kube-system get cm cilium-config -o jsonpath='{.data}' | tr ',' '\n' \
>   | grep -E '"(kube-proxy-replacement|bpf-lb-sock-hostns-only|cni-exclusive|enable-bpf-masquerade)"'
> ```
> Expected output (`enable-bpf-masquerade` is absent or `"false"`):
> ```
> "bpf-lb-sock-hostns-only":"true"
> "cni-exclusive":"false"
> "kube-proxy-replacement":"true"
> ```
> After lab `002`, `/etc/cni/net.d/05-cilium.conflist` on each node lists the `istio-cni` plugin after `cilium-cni`.
>
> Ambient sends kubelet health probes from the link-local address `169.254.7.127`. Cilium exempts kubelet probes from policy, but it treats this address as an ordinary source. If the cluster has a default-deny policy, allow that address into every endpoint, or ambient pods fail their readiness checks:
> ```bash
> kubectl apply -f - <<EOF
> apiVersion: cilium.io/v2
> kind: CiliumClusterwideNetworkPolicy
> metadata:
>   name: allow-ambient-hostprobes
> spec:
>   description: Allow SNATed kubelet health probes into ambient pods
>   enableDefaultDeny:
>     egress: false
>     ingress: false
>   endpointSelector: {}
>   ingress:
>   - fromCIDR:
>     - 169.254.7.127/32
> EOF
> ```
> Sources: Istio [platform prerequisites for Cilium](https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium) and Cilium [Istio integration](https://docs.cilium.io/en/stable/network/servicemesh/istio/).

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
