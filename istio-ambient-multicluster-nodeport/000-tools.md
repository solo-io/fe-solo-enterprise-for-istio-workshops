# TOOLING AND TROUBLESHOOTING
## CLI Tools useful for debugging

#### Solo's `istioctl` Binary:
```bash
ISTIO_VERSION=1.28.10-patch0
OS=$(uname | tr '[:upper:]' '[:lower:]' | sed -E 's/darwin/osx/')
ARCH=$(uname -m | sed -E 's/aarch/arm/; s/x86_64/amd64/; s/armv7l/armv7/')

INSTALL_DIR="."
mkdir -p "$INSTALL_DIR"
ISTIOCTL_URL="https://storage.googleapis.com/soloio-istio-binaries/release/${ISTIO_VERSION}-solo/istioctl-${ISTIO_VERSION}-solo-${OS}-${ARCH}.tar.gz"
curl -sSL "$ISTIOCTL_URL" | tar xzf - -C "$INSTALL_DIR"
mv "${INSTALL_DIR}/istioctl" "${INSTALL_DIR}/solo-istioctl"
chmod +x "${INSTALL_DIR}/solo-istioctl"
```

Useful commands:
```bash
#get version info of binary AND cluster in current kubectl context
./solo-istioctl version

#check peering health across both clusters
./solo-istioctl multicluster check --contexts=${KUBECONTEXT_CLUSTER1},${KUBECONTEXT_CLUSTER2}

#debug istio proxy status
./solo-istioctl proxy-status

#debug ZTunnel
./solo-istioctl zc 

#debug Waypoints
./solo-istioctl waypoint
```

Lab `007` creates the east-west and remote-peer Gateways with Solo's `peering` Helm chart.

## Optional Tools
#### K9s (CLI K8s control)
https://k9scli.io/ terminal UI for Kubernetes clusters.
On Mac / Linux:
```bash
 #install 
 brew install derailed/k9s/k9s
 #run
 k9s
```

#### Vegeta (CLI load generator)
https://github.com/tsenart/vegeta command line load generator with a text report
On Mac/Linux:
```bash
#install
brew install vegeta

#run for 10 minutes, 1 query per second then report
echo "GET http://yourhostname/path" | vegeta attack -duration=600s -rate=1 | vegeta report --type=text
```
#### ingress2gateway (Ingress to Gateway API converter)
https://github.com/kubernetes-sigs/ingress2gateway converts `Ingress` objects and some provider resources to Gateway API. Lab `017` downloads the release binary into the workshop directory.

#### Fortio (load generator)
https://github.com/fortio/fortio load generator with latency histograms. Lab `010` runs it as a pod in each cluster.
## Troubleshooting Resources:
Solo Istio service mesh troubleshooting (check here first)
https://docs.solo.io/istio/1.28.x/troubleshooting/service-mesh/

Multicluster peering (lab `007`)
https://docs.solo.io/istio/1.28.x/troubleshooting/service-mesh/multicluster/

OSS Ambient Debugging information
https://github.com/istio/istio/wiki/Troubleshooting-Istio-Ambient
