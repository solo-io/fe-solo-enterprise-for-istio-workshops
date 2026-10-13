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

#useful for removing Istio when iterating version / testing
./solo-istioctl uninstall --purge -y --context $context 

#create a quick east-west gateway for multicluster peering
./solo-istioctl multicluster expose --namespace istio-gateways --context ${context}

#check peering health across both clusters
./solo-istioctl multicluster check --contexts=${KUBECONTEXT_CLUSTER1},${KUBECONTEXT_CLUSTER2}

#debug istio proxy status
./solo-istioctl proxy-status

#debug ZTunnel
./solo-istioctl zc 

#debug Waypoints
./solo-istioctl waypoint
```

> **Note:** lab `006` applies the remote-peer Gateways with `kubectl`. In 1.28, `./solo-istioctl multicluster link`
> needs a LoadBalancer address on the east-west gateway.

## Optional Tools
#### K9s (CLI K8s control)
https://k9scli.io/ Takes a bit to get used, but is very powerful.
On Mac / Linux:
```bash
 #install 
 brew install derailed/k9s/k9s
 #run
 k9s
```

On Mac/Linux:
#### Vegeta (CLI load generator)
https://github.com/tsenart/vegeta Very easy to use command line load generator with a command line output result
On Mac/Linux:
```bash
#install
brew install vegeta

#run for 10 minutes, 1 query per second then report
echo "GET http://yourhostname/path" | vegeta attack -duration=600s -rate=1 | vegeta report --type=text
```
#### ingress2gateway (Ingress to Gateway API converter)
https://github.com/kubernetes-sigs/ingress2gateway converts `Ingress` objects and some provider resources to Gateway API. Lab `016` downloads the release binary into the workshop directory.

#### Fortio (load generator)
https://github.com/fortio/fortio Fortio has a lot of features for load testing and reporting, and can be run in a k8s pod. This is for more feature complete stress testing, for more quick and dirty results use Vegeta
On Mac/Linux:
```bash
brew install fortio
```
## Troubleshooting Resources:
Solo Istio service mesh troubleshooting (check here first)
https://docs.solo.io/istio/1.28.x/troubleshooting/service-mesh/

Multicluster peering (lab `006`)
https://docs.solo.io/istio/1.28.x/troubleshooting/service-mesh/multicluster/

OSS Ambient Debugging information
https://github.com/istio/istio/wiki/Troubleshooting-Istio-Ambient
