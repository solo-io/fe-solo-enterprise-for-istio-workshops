# Add Clusters to the NodePort Mesh

# Objectives
- Install Istio Ambient and Bookinfo on `cluster3` and `cluster4`, reusing the shared root of trust from lab `002`
- Create the east-west gateways on the new clusters with pinned NodePorts, before they peer
- Check NodePort reachability in every direction between the four clusters
- Peer the four clusters in a full mesh with one loop
- Copy the lab `007` and `008` policy baseline to the new clusters, and extend every policy to the new trust domains
- Fail productpage over across four clusters
- Run the drift check for every pair of clusters

## Prerequisites
- This lab assumes you have completed setup from labs `000-017`. Labs `007` and `008` set the policy baseline and the waypoints that this lab copies to the new clusters. If you skipped them, also skip the two policy sections below
- Two more Kubernetes clusters (≥ 1.29), each with its own kubectl context
- The nodes of all four clusters reach each other's node InternalIPs on the NodePort range
- `shared-root-trust-secret.yaml` and `solo-istioctl` from lab `002`, still in this directory
- `INGRESS_ADDR` from lab `005` is set in your shell

## Set cluster contexts
Set the contexts and mesh names for all four clusters
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER2=cluster2    # Recommended to keep as cluster2 for POC

export KUBECONTEXT_CLUSTER3=cluster3  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER3=cluster3    # Recommended to keep as cluster3 for POC
export KUBECONTEXT_CLUSTER4=cluster4  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER4=cluster4    # Recommended to keep as cluster4 for POC
[ -n "$INGRESS_ADDR" ] || echo "⚠️  INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 005 in this shell, or its port-forward fallback."
```

> **KinD users:** KinD automatically prefixes kubecontext names with `kind-`. You can set `KUBECONTEXT_CLUSTER3=kind-<cluster-name>` but keep `MESH_NAME_CLUSTER3=<cluster-name>` (without the `kind-` prefix). The mesh name is the Istio network name and trust domain prefix, and the policies in this lab match on it.

Export your Solo Trial License Key and the Istio version. Lab `017` rolled the mesh back to 1.28, so the new clusters join at the same version
```bash
export SOLO_TRIAL_LICENSE_KEY=<paste-your-key>
[ -n "$SOLO_TRIAL_LICENSE_KEY" ] || echo "⚠️  SOLO_TRIAL_LICENSE_KEY is not set. Istio installs with an empty license and enterprise features, including multicluster peering, then fail."
export ISTIO_VERSION=1.28.10-patch0
```

Lab `006` points the peers at the control-plane nodes with `PEER_NODE_SELECTOR`. Set it again in this shell. If you unset it in lab `006`, skip the `export` line:
```bash
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
echo "PEER_NODE_SELECTOR=${PEER_NODE_SELECTOR:-<unset: peers use the nodes that run an istio-eastwest pod>}"
```

Every block below loops over two lists. Each entry is `<kubectl context>=<mesh name>`. To add a fifth cluster later, append it to `NEW_CLUSTERS` and rebuild `ALL_CLUSTERS`:
```bash
NEW_CLUSTERS=("$KUBECONTEXT_CLUSTER3=$MESH_NAME_CLUSTER3" "$KUBECONTEXT_CLUSTER4=$MESH_NAME_CLUSTER4")
ALL_CLUSTERS=("$KUBECONTEXT_CLUSTER1=$MESH_NAME_CLUSTER1" "$KUBECONTEXT_CLUSTER2=$MESH_NAME_CLUSTER2" "${NEW_CLUSTERS[@]}")
printf '%s\n' "${ALL_CLUSTERS[@]}"
```

Expected output:
```
cluster1=cluster1
cluster2=cluster2
cluster3=cluster3
cluster4=cluster4
```

`${entry%%=*}` reads the context from an entry and `${entry#*=}` reads the mesh name. Both work in bash and zsh.

## Background

Each cluster holds one `istio-remote-peer-<peer>` Gateway for every other cluster, so the number of Gateways grows with the number of ordered pairs:

| Clusters | Remote-peer Gateways in the mesh | Per cluster | Firewall directions to open |
|---|---|---|---|
| 2 | 2 | 1 | 2 |
| 3 | 6 | 2 | 6 |
| 4 | 12 | 3 | 12 |
| N | N × (N - 1) | N - 1 | N × (N - 1) |

Each remote-peer Gateway is a copy of the peer's node IPs and NodePorts (lab `012`). In a four-cluster mesh, a replaced node or a recreated east-west Service in one cluster makes three Gateways stale, one in each of the other clusters. This lab adds the clusters in an order that keeps that cost low: it pins the NodePorts before the first peering, and it checks every direction through the firewall before it creates a Gateway.

Traffic still enters through the cluster1 ingress gateway. The new clusters run no ingress gateway: they serve the global `productpage` service and its backends.

## Merge the kubeconfigs

Every command switches clusters with `--context`, so all four contexts must be in the same `KUBECONFIG`. Check what is loaded:
```bash
kubectl config get-contexts
```

If the new contexts are missing, merge their kubeconfig files with your current one:
```bash
KUBECONFIG=~/.kube/config:/path/to/cluster3-kubeconfig.yaml:/path/to/cluster4-kubeconfig.yaml kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
export KUBECONFIG=/tmp/merged-kubeconfig.yaml
kubectl config get-contexts
```

## Install Istio on the New Clusters

The function below runs the install steps from lab `002` for one cluster: the shared root of trust, the network label, the Gateway API CRDs, istio-cni, istiod with peering enabled, and ztunnel. The values match lab `002`, with the context and mesh name as arguments.

> **GKE only:** apply `gke/resourcequota.yaml` to each new cluster and uncomment `platform: gke` in the istio-cni values, as in lab `002`.

```bash
install_istio() {
  local CTX=$1 MESH=$2
  kubectl create namespace istio-system --context $CTX --dry-run=client -o yaml | kubectl apply --context $CTX -f -
  kubectl apply -f shared-root-trust-secret.yaml --context $CTX

  helm upgrade --kube-context $CTX --install istio-base oci://us-docker.pkg.dev/soloio-img/istio-helm/base -n istio-system --version $ISTIO_VERSION-solo --create-namespace
  kubectl label namespace istio-system topology.istio.io/network=$MESH --overwrite --context $CTX

  kubectl get crd gateways.gateway.networking.k8s.io --context $CTX &> /dev/null || \
    { kubectl --context $CTX apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml; }

  helm upgrade --kube-context $CTX --install istio-cni oci://us-docker.pkg.dev/soloio-img/istio-helm/cni \
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
  kubectl rollout status ds/istio-cni-node -n istio-system --watch --timeout=90s --context $CTX

  helm upgrade --kube-context $CTX --install istiod oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod \
  -n istio-system \
  --version=$ISTIO_VERSION-solo \
  -f -<<EOF
profile: ambient
global:
  hub: us-docker.pkg.dev/soloio-img/istio
  tag: $ISTIO_VERSION-solo
  variant: distroless
  multiCluster:
    clusterName: $MESH
  network: $MESH
meshConfig:
  trustDomain: $MESH.local
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
platforms:
  peering:
    enabled: true
license:
  value: $SOLO_TRIAL_LICENSE_KEY
EOF
  kubectl rollout status deploy/istiod -n istio-system --watch --timeout=90s --context $CTX

  helm upgrade --kube-context $CTX --install ztunnel oci://us-docker.pkg.dev/soloio-img/istio-helm/ztunnel \
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
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
network: $MESH
multiCluster:
  clusterName: $MESH
EOF
  kubectl rollout status ds/ztunnel -n istio-system --watch --timeout=90s --context $CTX
}

for entry in "${NEW_CLUSTERS[@]}"; do
  install_istio "${entry%%=*}" "${entry#*=}"
done
```

Check the control plane in each new cluster
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  echo "--- ${entry%%=*} ---"
  kubectl get pods -n istio-system --context "${entry%%=*}"
done
```

Expected output (pod names differ on your machine):
```
--- cluster3 ---
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-brtd8      1/1     Running   0          38s
istio-cni-node-qswcx      1/1     Running   0          38s
istiod-84b6d6457f-h82pt   1/1     Running   0          31s
ztunnel-8zrt4             1/1     Running   0          26s
ztunnel-znbpl             1/1     Running   0          26s
--- cluster4 ---
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-6zjg9      1/1     Running   0          19s
istio-cni-node-z5ksv      1/1     Running   0          19s
istiod-5cfb659f78-dj8p8   1/1     Running   0          7s
ztunnel-b87nn             1/1     Running   0          2s
ztunnel-hv4bh             1/1     Running   0          2s
```

## Deploy Bookinfo on the New Clusters

Deploy Bookinfo as in lab `001`, set `CLUSTER_NAME` on reviews so the page shows which cluster served it, and enroll both namespaces in the mesh as in lab `004`:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  CTX=${entry%%=*}
  kubectl apply -f bookinfo/bookinfo-frontends.yaml --context $CTX
  kubectl apply -f bookinfo/bookinfo-backends.yaml --context $CTX
  for ns in bookinfo-frontends bookinfo-backends; do
    for deploy in $(kubectl get deploy -n $ns --context $CTX -o jsonpath='{.items[*].metadata.name}'); do
      kubectl rollout status deploy/"$deploy" -n $ns --watch --timeout=120s --context $CTX
    done
  done
  kubectl --context $CTX -n bookinfo-backends set env deploy -l app=reviews CLUSTER_NAME=${entry#*=}
  kubectl label namespace bookinfo-frontends bookinfo-backends istio.io/dataplane-mode=ambient --overwrite --context $CTX
done
```

Check that the workloads use HBONE
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER3 | grep -E "NAMESPACE|bookinfo"
```

Expected output:
```
NAMESPACE          POD NAME                                ADDRESS     NODE     WAYPOINT PROTOCOL
bookinfo-backends  details-v1-74658b4f9b-fxpx9             10.244.2.6  worker-1 None     HBONE
bookinfo-backends  ratings-v1-5d896f87b-4qj5s              10.244.2.7  worker-1 None     HBONE
bookinfo-backends  reviews-v1-55c4fbfdb6-9vcq7             10.244.2.11 worker-1 None     HBONE
bookinfo-backends  reviews-v2-787cd95cc4-bmhn2             10.244.2.13 worker-1 None     HBONE
bookinfo-backends  reviews-v3-74b6cbdd46-v88vf             10.244.2.12 worker-1 None     HBONE
bookinfo-frontends productpage-v1-59c74584cf-zlc2k         10.244.2.5  worker-1 None     HBONE
```

## Create the East-West Gateways with Pinned NodePorts

Lab `012` pinned the NodePorts of cluster1 and cluster2 after they peered. The new clusters pin before their first peering, so no peer ever holds a port that changes later. Each cluster has its own NodePort range, so every cluster can use the same numbers. Reuse the cluster1 values, and the firewall rules you opened for cluster1 cover the new clusters too:
```bash
EW_STATUS_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[?(@.port==15021)].nodePort}')
EW_HBONE_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
EW_XDS_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
echo "status $EW_STATUS_PORT, HBONE $EW_HBONE_PORT, xDS $EW_XDS_PORT"
```

Expected output (ports differ on your machine):
```
status 31767, HBONE 30454, xDS 32110
```

Create the `istio-eastwest-options` ConfigMap from lab `012` first. Then generate the east-west Gateway with `expose`, add the NodePort annotation as in lab `006`, and add the `parametersRef` to the ConfigMap before you apply it. Istio creates the Service with the pinned ports from the start:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  CTX=${entry%%=*}
  kubectl create ns istio-gateways --context $CTX --dry-run=client -o yaml | kubectl apply --context $CTX -f -
  kubectl apply --context $CTX -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-eastwest-options
  namespace: istio-gateways
data:
  service: |
    spec:
      ports:
      # Keep Istio's port names: Istio reads the protocol from the tls- prefix
      - name: status-port
        port: 15021
        nodePort: $EW_STATUS_PORT
      - name: tls-hbone
        port: 15008
        nodePort: $EW_HBONE_PORT
      - name: tls-xds
        port: 15012
        nodePort: $EW_XDS_PORT
EOF
  ./solo-istioctl multicluster expose --namespace istio-gateways --context $CTX --generate \
    | kubectl annotate --local -f - networking.istio.io/service-type=NodePort -o yaml \
    | kubectl patch --local -f - --type=merge -o yaml \
        -p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"istio-eastwest-options"}}}}' \
    | kubectl apply --context $CTX -f -
  kubectl rollout status deploy/istio-eastwest -n istio-gateways --watch --timeout=90s --context $CTX
done
```

Check the Service in all four clusters
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  echo "${entry%%=*}: $(kubectl get svc istio-eastwest -n istio-gateways --context "${entry%%=*}" -o jsonpath='{.spec.type} {.spec.ports[*].nodePort}')"
done
```

Expected output (ports differ on your machine):
```
cluster1: NodePort 31767 30454 32110
cluster2: NodePort 30757 31600 32633
cluster3: NodePort 31767 30454 32110
cluster4: NodePort 31767 30454 32110
```

> **A pinned port is already taken?** The Service fails to update if another Service in the cluster holds the port. `kubectl get svc -A --context <ctx> | grep <port>` finds the holder. Pick other values for the new clusters and open them in the firewall.

## Check Reachability Between Every Pair

Each direction between two clusters is a separate firewall path, and the four clusters have twelve. A gap in one direction shows up later as failover that works one way only. Check every direction before you peer.

The function below lists the addresses that `apply_remote_peer` will write into a remote-peer Gateway, using the same rule: nodes that match `PEER_NODE_SELECTOR`, or the nodes that run a ready `istio-eastwest` pod when the selector is unset:
```bash
peer_node_ips() {
  local PEER_CTX=$1
  if [ -n "$PEER_NODE_SELECTOR" ]; then
    kubectl get nodes -l "$PEER_NODE_SELECTOR" --context $PEER_CTX \
      -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
  else
    kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest \
      --field-selector=status.phase=Running \
      --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.hostIP} {.metadata.deletionTimestamp}{"\n"}{end}' \
      | awk 'NF == 1 { print $1 }'
  fi | sort -u
}
```

Start a probe pod in the `default` namespace of every cluster. `default` is outside the mesh, so the probe opens a plain TCP connection from the pod network, the same path istiod and ztunnel take to a peer:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  kubectl run reach-probe -n default --image=curlimages/curl:8.22.0 --restart=Never --context "${entry%%=*}" \
    --command -- sleep 3600 2>/dev/null
done
for entry in "${ALL_CLUSTERS[@]}"; do
  kubectl wait --for=condition=Ready pod/reach-probe -n default --timeout=60s --context "${entry%%=*}"
done
```

Probe the HBONE and xDS NodePorts of every peer address from every other cluster:
```bash
check_reach() {
  local SRC_CTX=$1 DST_CTX=$2 HBONE_PORT XDS_PORT IP PORT
  HBONE_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $DST_CTX -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  XDS_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $DST_CTX -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  for IP in $(peer_node_ips $DST_CTX); do
    for PORT in $HBONE_PORT $XDS_PORT; do
      if kubectl exec reach-probe -n default --context $SRC_CTX -- nc -z -w 3 $IP $PORT 2>/dev/null; then
        echo "OK    $SRC_CTX -> $DST_CTX $IP:$PORT"
      else
        echo "FAIL  $SRC_CTX -> $DST_CTX $IP:$PORT"
      fi
    done
  done
}

for src in "${ALL_CLUSTERS[@]}"; do
  for dst in "${ALL_CLUSTERS[@]}"; do
    [ "$src" = "$dst" ] && continue
    check_reach "${src%%=*}" "${dst%%=*}"
  done
done
```

Expected output (abridged; addresses and ports differ on your machine):
```
OK    cluster1 -> cluster2 172.30.0.4:31600
OK    cluster1 -> cluster2 172.30.0.4:32633
OK    cluster1 -> cluster3 172.30.0.6:30454
OK    cluster1 -> cluster3 172.30.0.6:32110
OK    cluster1 -> cluster4 172.30.0.8:30454
OK    cluster1 -> cluster4 172.30.0.8:32110
OK    cluster2 -> cluster1 172.30.0.2:30454
OK    cluster2 -> cluster1 172.30.0.2:32110
...
OK    cluster4 -> cluster3 172.30.0.6:30454
OK    cluster4 -> cluster3 172.30.0.6:32110
```

The full output has 24 lines: two ports for each of the twelve directions. Fix every `FAIL` line before you peer: it names the source cluster, the destination node and the port to open.

## Peer the Four Clusters

The `apply_remote_peer` function from lab `006` is repeated here so this lab works in a new shell:
```bash
apply_remote_peer() {
  local LOCAL_CTX=$1 PEER_CTX=$2 PEER_MESH=$3 HBONE_PORT XDS_PORT PEER_IPS PEER_ADDRESSES
  HBONE_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX \
    -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  XDS_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX \
    -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  if [ -n "$PEER_NODE_SELECTOR" ]; then
    PEER_IPS=$(kubectl get nodes -l "$PEER_NODE_SELECTOR" --context $PEER_CTX \
      -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
  else
    PEER_IPS=$(kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest \
      --field-selector=status.phase=Running \
      --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.hostIP} {.metadata.deletionTimestamp}{"\n"}{end}' \
      | awk 'NF == 1 { print $1 }')
  fi
  PEER_ADDRESSES=$(printf '%s\n' "$PEER_IPS" | sort -u \
    | awk 'NF { printf "  - type: IPAddress\n    value: %s\n", $1 }')
  if [ -z "$HBONE_PORT" ] || [ -z "$XDS_PORT" ] || [ -z "$PEER_ADDRESSES" ]; then
    echo "No istio-eastwest NodePorts or peer node addresses found in $PEER_CTX. Finish the steps above in $PEER_CTX first."
    return 1
  fi
  echo "istio-remote-peer-$PEER_MESH in $LOCAL_CTX: HBONE $HBONE_PORT, xDS $XDS_PORT"
  kubectl apply --context $LOCAL_CTX -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-$PEER_MESH
  namespace: istio-gateways
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: $PEER_MESH.local
  labels:
    topology.istio.io/cluster: $PEER_MESH
    topology.istio.io/network: $PEER_MESH
spec:
  gatewayClassName: istio-remote
  addresses:
$PEER_ADDRESSES
  listeners:
  - name: cross-network
    port: $HBONE_PORT
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: $XDS_PORT
    protocol: TLS
    tls:
      mode: Passthrough
EOF
}
```

Apply a remote-peer Gateway for every ordered pair. The loop creates the ten new Gateways. It also re-applies the two that cluster1 and cluster2 already hold, with the same addresses and ports:
```bash
for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    apply_remote_peer "${local%%=*}" "${peer%%=*}" "${peer#*=}"
  done
done
```

Expected output (abridged):
```
istio-remote-peer-cluster2 in cluster1: HBONE 31600, xDS 32633
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster2 configured
istio-remote-peer-cluster3 in cluster1: HBONE 30454, xDS 32110
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster3 created
istio-remote-peer-cluster4 in cluster1: HBONE 30454, xDS 32110
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster4 created
...
```

Wait for every remote-peer Gateway to be programmed, and list them per cluster
```bash
for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    kubectl wait --for=condition=Programmed gateway/istio-remote-peer-${peer#*=} -n istio-gateways \
      --timeout=120s --context "${local%%=*}" > /dev/null
  done
  echo "${local%%=*}: $(kubectl get gateway -n istio-gateways --context "${local%%=*}" -o name | grep remote-peer | sed 's|.*/||' | tr '\n' ' ')"
done
```

Expected output:
```
cluster1: istio-remote-peer-cluster2 istio-remote-peer-cluster3 istio-remote-peer-cluster4
cluster2: istio-remote-peer-cluster1 istio-remote-peer-cluster3 istio-remote-peer-cluster4
cluster3: istio-remote-peer-cluster1 istio-remote-peer-cluster2 istio-remote-peer-cluster4
cluster4: istio-remote-peer-cluster1 istio-remote-peer-cluster2 istio-remote-peer-cluster3
```

Check the peering from all four sides
```bash
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2,$KUBECONTEXT_CLUSTER3,$KUBECONTEXT_CLUSTER4" 2>&1 | grep -A3 "Peers Check"
```

Expected output (abridged; addresses differ on your machine):
```
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
     ✅ Connected to cluster3 via 172.30.0.6
     ✅ Connected to cluster4 via 172.30.0.8
--
✅ Peers Check: all clusters connected
     ✅ Connected to cluster1 via 172.30.0.2
     ✅ Connected to cluster3 via 172.30.0.6
     ✅ Connected to cluster4 via 172.30.0.8
...
```

Each of the four blocks lists the other three clusters.

## Apply the Policy Baseline on the New Clusters

cluster1 and cluster2 run the lab `007` baseline and the lab `008` waypoints. A new cluster starts with none of it, so any workload that shares the root CA can reach its Bookinfo pods. Apply the same baseline before the new clusters serve the global service:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  CTX=${entry%%=*}
  kubectl apply --context $CTX -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
  kubectl apply -f auth-policy/allow-nothing.yaml -f auth-policy/productpage-auth.yaml --context $CTX
  kubectl apply --context $CTX -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: bookinfo-backends
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
EOF
  kubectl rollout status deploy/waypoint -n bookinfo-backends --watch --timeout=90s --context $CTX
  kubectl label namespace bookinfo-backends istio.io/use-waypoint=waypoint --overwrite --context $CTX
  kubectl apply -f auth-policy/waypoint-auth.yaml --context $CTX
done
```

These are the files cluster1 and cluster2 use, and their `principals` lists name only the `cluster1.local` and `cluster2.local` trust domains.

## Add the New Clusters to the Global Service

Label and annotate productpage in the new clusters, as lab `006` did in cluster1 and cluster2:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  kubectl --context "${entry%%=*}" -n bookinfo-frontends label service productpage solo.io/service-scope=global --overwrite
  kubectl --context "${entry%%=*}" -n bookinfo-frontends annotate service productpage networking.istio.io/traffic-distribution=PreferNetwork --overwrite
done
sleep 5
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen.bookinfo"
```

Expected output:
```
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     4/4
```

The global productpage in cluster1 now has four endpoints, one per cluster. List the network gateways that ztunnel in cluster1 knows:
```bash
./solo-istioctl zc all -n istio-system --context $KUBECONTEXT_CLUSTER1 -o json | grep -oE '"NetworkGateway/[^"]*"' | sort -u
```

Expected output (addresses and ports differ on your machine):
```
"NetworkGateway/cluster1/10.96.191.108/15008"
"NetworkGateway/cluster2/172.30.0.4/31600"
"NetworkGateway/cluster3/172.30.0.6/30454"
"NetworkGateway/cluster4/172.30.0.8/30454"
```

The first entry is the local east-west gateway at its ClusterIP. ztunnel reaches each of the three peers at a node IP and HBONE NodePort from its remote-peer Gateway.

## Fail Over Across Four Clusters

Scale productpage to zero in cluster1, then send 20 requests and count which cluster served each one. The page names the reviews cluster, and productpage calls the reviews in its own cluster:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
for i in $(seq 1 20); do
  curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[0-9]+|Error fetching product details" | head -1
done | sort | uniq -c
```

Expected output (counts vary):
```
  13 Error fetching product details
   7 cluster2
```

With no local productpage, `PreferNetwork` spreads requests across the three remote clusters. cluster2 serves complete pages. The requests that reach cluster3 and cluster4 render productpage, but without details or reviews. Call details from productpage in cluster3 to see why:
```bash
kubectl exec deploy/productpage-v1 -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER3 -- python3 -c "
import urllib.request, urllib.error
try: print(urllib.request.urlopen('http://details.bookinfo-backends:9080/details/0').getcode())
except urllib.error.HTTPError as e: print(e.code, e.read().decode())"
```

Expected output:
```
403 RBAC: access denied
```

The cluster3 waypoint denied the call. `details-waypoint-auth` lists the productpage identity in `cluster1.local` and `cluster2.local` only, and productpage in cluster3 runs as `cluster3.local/ns/bookinfo-frontends/sa/bookinfo-productpage`. Lab `007` lists the trust domains on purpose, so an identity from another trust domain that shares the root CA is denied. The cost is that every new cluster's trust domain has to be added to every policy, in every cluster.

## Extend the Policies to the New Trust Domains

The function below prints a policy file with one `principals` entry per mesh name in place of the `cluster1.local` and `cluster2.local` entries:
```bash
MESHES=""
for entry in "${ALL_CLUSTERS[@]}"; do MESHES="$MESHES ${entry#*=}"; done

extend_trust_domains() {
  awk -v meshes="$MESHES" '
    /- cluster2\.local\// { next }
    /- cluster1\.local\// {
      n = split(meshes, m, " ")
      for (i = 1; i <= n; i++) { line = $0; sub(/cluster1\.local/, m[i] ".local", line); print line }
      next
    }
    { print }' "$1"
}

extend_trust_domains auth-policy/productpage-auth.yaml | tail -6
```

Expected output:
```
    - source:
        principals:
        - cluster1.local/ns/istio-system/sa/ingress-istio
        - cluster2.local/ns/istio-system/sa/ingress-istio
        - cluster3.local/ns/istio-system/sa/ingress-istio
        - cluster4.local/ns/istio-system/sa/ingress-istio
```

Apply the extended policies in all four clusters, so every cluster accepts the same identities. Bookinfo backends are local to each cluster today. Once a backend service is global, a call from productpage in cluster3 can land in cluster1 with a `cluster3.local` identity:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  extend_trust_domains auth-policy/productpage-auth.yaml | kubectl apply --context "${entry%%=*}" -f -
  extend_trust_domains auth-policy/waypoint-auth.yaml | kubectl apply --context "${entry%%=*}" -f -
done
```

> **In production, generate the policies from the cluster list.** Keep the list of trust domains in one place, the same list that drives the peering loop, and render every policy from it. A cluster added to the peering and left out of the policies fails the way this section showed.

Send the 20 requests again
```bash
sleep 3
for i in $(seq 1 20); do
  curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[0-9]+|Error fetching product details" | head -1
done | sort | uniq -c
```

Expected output (counts vary):
```
   6 cluster2
   9 cluster3
   5 cluster4
```

Every request now renders a complete page, from one of the three remaining clusters.

Scale productpage to zero in cluster2 and cluster3 as well. Only cluster4 is left:
```bash
for CTX in $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER3; do
  kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $CTX
  kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $CTX
done
for i in $(seq 1 10); do
  curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[0-9]+|Error fetching product details" | head -1
done | sort | uniq -c
```

Expected output:
```
  10 cluster4
```

Restore productpage in cluster1, cluster2 and cluster3. With a healthy local endpoint, `PreferNetwork` sends traffic back to cluster1:
```bash
for CTX in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER3; do
  kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 1 --context $CTX
  kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $CTX
done
sleep 5
for i in $(seq 1 10); do
  curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[0-9]+|Error fetching product details" | head -1
done | sort | uniq -c
```

Expected output:
```
  10 cluster1
```

## Check Drift Across Every Pair

The `check_peer_drift` function from lab `012` is repeated here. Run it for all twelve remote-peer Gateways:
```bash
check_peer_drift() {
  local LOCAL_CTX=$1 PEER_CTX=$2 PEER_MESH=$3 GW WANT_HBONE WANT_XDS HAVE_HBONE HAVE_XDS PEER_NODE_IPS ADDR STATUS=OK
  GW=istio-remote-peer-$PEER_MESH
  WANT_HBONE=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  WANT_XDS=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  HAVE_HBONE=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.listeners[?(@.name=="cross-network")].port}')
  HAVE_XDS=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.listeners[?(@.name=="xds-tls")].port}')
  PEER_NODE_IPS=" $(kubectl get nodes --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address} {end}')"
  if [ "$WANT_HBONE" != "$HAVE_HBONE" ] || [ "$WANT_XDS" != "$HAVE_XDS" ]; then
    echo "DRIFT  $LOCAL_CTX/$GW: listener ports $HAVE_HBONE/$HAVE_XDS, $PEER_CTX NodePorts are $WANT_HBONE/$WANT_XDS"
    STATUS=DRIFT
  fi
  for ADDR in $(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.addresses[*].value}'); do
    case "$PEER_NODE_IPS" in
      *" $ADDR "*) ;;
      *) echo "DRIFT  $LOCAL_CTX/$GW: address $ADDR is not a node in $PEER_CTX"; STATUS=DRIFT ;;
    esac
  done
  [ $STATUS = OK ] && echo "OK     $LOCAL_CTX/$GW: $(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.addresses[*].value}') ports $HAVE_HBONE/$HAVE_XDS"
  [ $STATUS = OK ]
}

for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    check_peer_drift "${local%%=*}" "${peer%%=*}" "${peer#*=}"
  done
done
```

Expected output (addresses and ports differ on your machine):
```
OK     cluster1/istio-remote-peer-cluster2: 172.30.0.4 ports 31600/32633
OK     cluster1/istio-remote-peer-cluster3: 172.30.0.6 ports 30454/32110
OK     cluster1/istio-remote-peer-cluster4: 172.30.0.8 ports 30454/32110
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2 ports 30454/32110
...
OK     cluster4/istio-remote-peer-cluster2: 172.30.0.4 ports 31600/32633
OK     cluster4/istio-remote-peer-cluster3: 172.30.0.6 ports 30454/32110
```

Run this loop on a schedule. When a control-plane node in cluster3 is replaced, it reports three `DRIFT` lines, one in each cluster that peers with cluster3, and the `apply_remote_peer` loop above repairs all three.

| Lifecycle event | Two clusters | Four clusters |
|---|---|---|
| A peer node in one cluster is replaced | 1 stale Gateway | 3 stale Gateways, one in each other cluster |
| A fifth cluster joins | | 8 new Gateways: 4 in the new cluster, 1 in each existing cluster. Add its trust domain to every policy in all five clusters |
| An upgrade (lab `017`) | Drift check for 2 Gateways first | Drift check for 12 Gateways first, then upgrade one cluster at a time |

## Cleanup

Remove the probe pods, and take cluster3 and cluster4 out of the mesh. Move traffic off them first, as lab `012` describes. Then delete their remote-peer Gateways on every side, and put the two-cluster policies back in cluster1 and cluster2:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  kubectl delete pod reach-probe -n default --context "${entry%%=*}" --ignore-not-found
done
for entry in "${NEW_CLUSTERS[@]}"; do
  for other in "${ALL_CLUSTERS[@]}"; do
    [ "$other" = "$entry" ] && continue
    kubectl delete gateway istio-remote-peer-${entry#*=} -n istio-gateways --context "${other%%=*}" --ignore-not-found
    kubectl delete gateway istio-remote-peer-${other#*=} -n istio-gateways --context "${entry%%=*}" --ignore-not-found
  done
done
for CTX in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply -f auth-policy/productpage-auth.yaml -f auth-policy/waypoint-auth.yaml --context $CTX
done
sleep 5
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen.bookinfo"
```

Expected output:
```
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     2/2
```

The global productpage is back to two endpoints. Istio and Bookinfo stay installed on cluster3 and cluster4. Lab `019` removes them when you add the two contexts to its cluster list.

## Next Steps
At this point we have completed the following objectives:
- Installed Istio Ambient and Bookinfo on `cluster3` and `cluster4` with the shared root of trust
- Created the east-west gateways on the new clusters with NodePorts pinned before the first peering
- Checked NodePort reachability in all twelve directions between the four clusters
- Peered the four clusters in a full mesh with one loop
- Copied the policy baseline to the new clusters, and extended every policy to the four trust domains
- Failed productpage over across four clusters
- Ran the drift check for all twelve remote-peer Gateways

In the next step `019` we will remove everything this workshop created
