# Install Solo Istio Ambient on cluster1

# Objectives
- Deploy Istio on Kubernetes with Helm based install
- Install Istio Ambient Mesh

![](../images/install-istio-1.png)

## Prerequisites
- This lab assumes you have read through and completed any setup from the `000` labs

## Set cluster contexts
In this workshop, you can use your preferred cluster context. To set it, run the following command, replacing cluster1 with your desired context name
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
```

> **KinD users:** set `KUBECONTEXT_CLUSTER1=kind-cluster1` and keep `MESH_NAME_CLUSTER1=cluster1`. The mesh name is the Istio network name, and it must match the `topology.istio.io/network` label and the ztunnel network. A mismatch makes ztunnel bypass waypoints.

Set your Solo Trial License Key and the Istio version:
```bash
export SOLO_TRIAL_LICENSE_KEY=$SOLO_TRIAL_LICENSE_KEY
[ -n "$SOLO_TRIAL_LICENSE_KEY" ] || echo "WARNING: SOLO_TRIAL_LICENSE_KEY is not set. Istio installs with an empty license and enterprise features, including multicluster peering, then fail."
export ISTIO_VERSION=1.28.10-patch0
```

## Install Solo istioctl
Later labs use `solo-istioctl` to inspect ztunnel and peering:
```bash
OS=$(uname | tr '[:upper:]' '[:lower:]' | sed -E 's/darwin/osx/')
ARCH=$(uname -m | sed -E 's/aarch/arm/; s/x86_64/amd64/; s/armv7l/armv7/')

INSTALL_DIR="."
mkdir -p "$INSTALL_DIR"
ISTIOCTL_URL="https://storage.googleapis.com/soloio-istio-binaries/release/${ISTIO_VERSION}-solo/istioctl-${ISTIO_VERSION}-solo-${OS}-${ARCH}.tar.gz"
curl -sSL "$ISTIOCTL_URL" | tar xzf - -C "$INSTALL_DIR"
mv "${INSTALL_DIR}/istioctl" "${INSTALL_DIR}/solo-istioctl"
chmod +x "${INSTALL_DIR}/solo-istioctl"
```

Check the `istioctl version`
```bash
./solo-istioctl version
```

## Generate shared root trust secret

Both clusters must share the same root of trust so that workloads can verify each other's mTLS certificates across cluster boundaries. Generate a self-signed root CA and write it to a local file that will be applied to both clusters:
```bash
WORK_DIR=$(mktemp -d)

cat > "$WORK_DIR/root-openssl.cnf" <<'CNFEOF'
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca

[ dn ]
C  = US
ST = California
L  = San Francisco
O  = MyOrg
OU = MyUnit
CN = root-cert

[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNFEOF

cat > "$WORK_DIR/intermediate-req.cnf" <<'CNFEOF'
[ req ]
prompt = no
distinguished_name = dn

[ dn ]
C  = US
ST = California
L  = San Francisco
O  = MyOrg
OU = MyUnit
CN = istio-intermediate-ca
CNFEOF

cat > "$WORK_DIR/ca-ext.cnf" <<'CNFEOF'
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CNFEOF

openssl req -x509 -sha256 -nodes -days 3650 \
  -newkey rsa:2048 \
  -keyout "$WORK_DIR/root-key.pem" \
  -out "$WORK_DIR/root-cert.pem" \
  -config "$WORK_DIR/root-openssl.cnf" \
  -extensions v3_ca

openssl req -new -nodes -newkey rsa:2048 \
  -keyout "$WORK_DIR/ca-key.pem" \
  -out "$WORK_DIR/ca.csr" \
  -config "$WORK_DIR/intermediate-req.cnf"

openssl x509 -req -sha256 -days 3650 \
  -in "$WORK_DIR/ca.csr" \
  -CA "$WORK_DIR/root-cert.pem" \
  -CAkey "$WORK_DIR/root-key.pem" \
  -CAcreateserial \
  -out "$WORK_DIR/ca-cert.pem" \
  -extfile "$WORK_DIR/ca-ext.cnf" \
  -extensions v3_ca

cat "$WORK_DIR/ca-cert.pem" "$WORK_DIR/root-cert.pem" > "$WORK_DIR/cert-chain.pem"

cat <<EOF > shared-root-trust-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cacerts
  namespace: istio-system
type: Opaque
data:
  ca-cert.pem: $(base64 < "$WORK_DIR/ca-cert.pem" | tr -d '\n')
  ca-key.pem: $(base64 < "$WORK_DIR/ca-key.pem" | tr -d '\n')
  cert-chain.pem: $(base64 < "$WORK_DIR/cert-chain.pem" | tr -d '\n')
  root-cert.pem: $(base64 < "$WORK_DIR/root-cert.pem" | tr -d '\n')
EOF

rm -rf "$WORK_DIR"
echo "Generated shared-root-trust-secret.yaml"
```

## Create istio-system namespace and apply shared root trust secret in cluster1
```bash
kubectl create namespace istio-system --context $KUBECONTEXT_CLUSTER1 --dry-run=client -o yaml | kubectl apply --context $KUBECONTEXT_CLUSTER1 -f -
kubectl apply -f shared-root-trust-secret.yaml --context $KUBECONTEXT_CLUSTER1
```

## Install Istio using Helm on cluster1

Install istio-base
```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install istio-base oci://us-docker.pkg.dev/soloio-img/istio-helm/base -n istio-system --version $ISTIO_VERSION-solo --create-namespace

kubectl label namespace istio-system topology.istio.io/network=$MESH_NAME_CLUSTER1 --overwrite --context $KUBECONTEXT_CLUSTER1
```

Install the Gateway API `v1.4.1` CRDs if they are missing. Istio 1.28 is built against this release.
```bash
kubectl get crd gateways.gateway.networking.k8s.io --context $KUBECONTEXT_CLUSTER1 &> /dev/null || \
  { kubectl --context $KUBECONTEXT_CLUSTER1 apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml; }
```

> **GKE only:** GKE runs `system-node-critical` pods only in namespaces with a ResourceQuota. Allow `istio-cni` to run in `istio-system`:
> ```bash
> kubectl apply -f gke/resourcequota.yaml --context $KUBECONTEXT_CLUSTER1
> ```

> **Cilium with kube-proxy replacement:** the istio-cni values below stay the same. Before you install istio-cni, check the Cilium settings ambient needs:
> ```bash
> kubectl -n kube-system get cm cilium-config --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.data}' | tr ',' '\n' \
>   | grep -E '"(kube-proxy-replacement|bpf-lb-sock-hostns-only|cni-exclusive|enable-bpf-masquerade)"'
> ```
> Expected output (`enable-bpf-masquerade` is absent or `"false"`):
> ```
> "bpf-lb-sock-hostns-only":"true"
> "cni-exclusive":"false"
> "kube-proxy-replacement":"true"
> ```
> If a value differs, set it in the Cilium Helm values and upgrade the Cilium release:
> ```yaml
> cni:
>   exclusive: false          # keeps the istio-cni plugin in Cilium's chained CNI config
> socketLB:
>   hostNamespaceOnly: true   # pods keep the Service IP, so ztunnel picks the endpoint
> bpf:
>   masquerade: false         # the default. eBPF masquerading breaks ambient health probes
> ```
> With `cni.exclusive=true`, Cilium removes the istio-cni plugin from the CNI config, and new pods start without ztunnel redirection.
>
> Sources: Istio [platform prerequisites for Cilium](https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium) and Cilium [Istio integration](https://docs.cilium.io/en/stable/network/servicemesh/istio/).

Install istio-cni

> **GKE users:** Uncomment `platform: gke` under `global` in the values below before running this command.

```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install istio-cni oci://us-docker.pkg.dev/soloio-img/istio-helm/cni \
-n istio-system \
--version=$ISTIO_VERSION-solo \
-f -<<EOF
profile: ambient
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
global:
  # uncomment if using GKE
  #platform: gke
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: $ISTIO_VERSION-solo
  variant: distroless
EOF
```

Wait for rollout to complete
```bash
kubectl rollout status ds/istio-cni-node -n istio-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

Install istiod
```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install istiod oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod \
-n istio-system \
--version=$ISTIO_VERSION-solo \
-f -<<EOF
profile: ambient
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: $ISTIO_VERSION-solo
  variant: distroless
  multiCluster:
    clusterName: $MESH_NAME_CLUSTER1
  network: $MESH_NAME_CLUSTER1
meshConfig:
  trustDomain: $MESH_NAME_CLUSTER1.local
env:
  # Enables assigning multi-cluster services an IP address
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  # Required if you have distinct trust domains per-cluster
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
# Required to enable multi-cluster support
platforms:
  peering:
    enabled: true
license:
  value: $SOLO_TRIAL_LICENSE_KEY
EOF
```

Wait for rollout to complete
```bash
kubectl rollout status deploy/istiod -n istio-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

Install ztunnel
```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install ztunnel oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel \
-n istio-system \
--version=$ISTIO_VERSION-solo \
-f -<<EOF
profile: ambient
logLevel: info
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: $ISTIO_VERSION-solo
  variant: distroless
resources:
  requests:
      cpu: 500m
      memory: 2048Mi
istioNamespace: istio-system
env:
  L7_ENABLED: "true"
  # Required if you have distinct trust domains per-cluster
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
# Must match the setting during Istio installation
network: $MESH_NAME_CLUSTER1
multiCluster:
  clusterName: $MESH_NAME_CLUSTER1
EOF
```

Wait for rollout to complete
```bash
kubectl rollout status ds/ztunnel -n istio-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

## Validate the installation
```bash
kubectl get pods -n istio-system --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-799nr      1/1     Running   0          14s
istio-cni-node-ltn2g      1/1     Running   0          14s
istiod-55ddf67c4f-x9xfh   1/1     Running   0          7s
ztunnel-m96zt             1/1     Running   0          2s
ztunnel-tzxkk             1/1     Running   0          2s
```

## Next Steps
At this point we have completed the following objectives
- Deployed Istio on Kubernetes with Helm based install on cluster1
- Installed Istio Ambient Mesh on cluster1

In the next step `003` we will install Istio on cluster2
