# Add Clusters to the NodePort Mesh

# Objectives
- Install Istio Ambient and Bookinfo on `cluster3` and `cluster4`, reusing the shared root of trust from lab `002`
- Create the east-west gateways on the new clusters from the `peering` chart, with the same fixed NodePorts
- Check NodePort reachability in every direction between the four clusters
- Peer the four clusters in a full mesh with one loop over the `peering` chart
- Copy the lab `008` and `009` policy baseline to the new clusters, and extend every policy to the new trust domains
- Fail productpage over across four clusters
- Run the drift check for every pair of clusters

## Prerequisites
- This lab assumes you have completed setup from labs `000-018`. Labs `008` and `009` set the policy baseline and the waypoints that this lab copies to the new clusters. If you skipped them, also skip the two policy sections below
- Two more Kubernetes clusters (≥ 1.29), each with its own kubectl context
- The nodes of all four clusters reach each other's node InternalIPs on the NodePort range
- `shared-root-trust-secret.yaml` and `solo-istioctl` from lab `002`, still in this directory
- `INGRESS_ADDR` from lab `006` is set in your shell

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
[ -n "$INGRESS_ADDR" ] || echo "WARNING: INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

> **KinD users:** KinD automatically prefixes kubecontext names with `kind-`. You can set `KUBECONTEXT_CLUSTER3=kind-<cluster-name>` but keep `MESH_NAME_CLUSTER3=<cluster-name>` (without the `kind-` prefix). The mesh name is the Istio network name and trust domain prefix, and the policies in this lab match on it.

Export your Solo Trial License Key and the Istio version. Lab `018` rolled the mesh back to 1.28, so the new clusters join at the same version
```bash
export SOLO_TRIAL_LICENSE_KEY=<paste-your-key>
[ -n "$SOLO_TRIAL_LICENSE_KEY" ] || echo "WARNING: SOLO_TRIAL_LICENSE_KEY is not set. Istio installs with an empty license and enterprise features, including multicluster peering, then fail."
export ISTIO_VERSION=1.28.10-patch0
```

Set the chart version, the NodePorts and the peer node selector from lab `007`. If you changed any of them in lab `007`, use your values:
```bash
export PEERING_CHART_VERSION=1.29.7-patch0
export EW_STATUS_NODEPORT=31521
export EW_HBONE_NODEPORT=31508
export EW_XDS_NODEPORT=31512
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
```

Every block below loops over two lists, in the `<kubectl context>=<mesh name>` format from lab `007`. To add a fifth cluster later, append it to `NEW_CLUSTERS` and rebuild `ALL_CLUSTERS`:
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

## Background

Each cluster holds one `istio-remote-peer-<peer>` Gateway for every other cluster, all in its `peering-remote` release, so the number of Gateways grows with the number of ordered pairs:

| Clusters | Remote-peer Gateways in the mesh | Per cluster | Firewall directions to open |
|---|---|---|---|
| 2 | 2 | 1 | 2 |
| 3 | 6 | 2 | 6 |
| 4 | 12 | 3 | 12 |
| N | N × (N - 1) | N - 1 | N × (N - 1) |

Each remote-peer Gateway holds one node address of its peer (lab `013`). The new clusters use the same fixed NodePorts as cluster1 and cluster2, and this lab checks every direction through the firewall before it peers them.

Traffic still enters through agentgateway in cluster1. The new clusters run no ingress gateway: they serve the global `productpage` service and its backends.

## Merge the kubeconfigs

Every command switches clusters with `--context`, so all four contexts must be in the same `KUBECONFIG`. Check what is loaded:
```bash
kubectl config get-contexts
```

If the new contexts are missing, merge their kubeconfig files with your current one:
```bash
KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}:/path/to/cluster3-kubeconfig.yaml:/path/to/cluster4-kubeconfig.yaml kubectl config view --flatten > /tmp/merged-kubeconfig.yaml
export KUBECONFIG=/tmp/merged-kubeconfig.yaml
kubectl config get-contexts
```

## Install Istio on the New Clusters

The `install_istio` function runs the install steps from lab `002` for one cluster: the shared root of trust, the network label, the Gateway API CRDs, istio-cni, istiod with peering enabled, and ztunnel. The values match lab `002`, with the context and mesh name as arguments. Define it:

> **GKE only:** apply `gke/resourcequota.yaml` to each new cluster and uncomment `platform: gke` in the istio-cni values, as in lab `002`.

```bash
install_istio() {
  local CTX=$1 MESH=$2
  kubectl create namespace istio-system --context $CTX --dry-run=client -o yaml | kubectl apply --context $CTX -f -
  kubectl apply -f shared-root-trust-secret.yaml --context $CTX

  helm upgrade --kube-context $CTX --install istio-base oci://us-docker.pkg.dev/soloio-img/istio-helm/base -n istio-system --version $ISTIO_VERSION-solo --create-namespace | grep -E "^STATUS"
  kubectl label namespace istio-system topology.istio.io/network=$MESH --overwrite --context $CTX

  kubectl get crd gateways.gateway.networking.k8s.io --context $CTX &> /dev/null || \
    { kubectl --context $CTX apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml; }

  helm upgrade --kube-context $CTX --install istio-cni oci://us-docker.pkg.dev/soloio-img/istio-helm/cni \
  -n istio-system \
  --version=$ISTIO_VERSION-solo \
  -f -<<EOF | grep -E "^STATUS"
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
  -f -<<EOF | grep -E "^STATUS"
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
  -f -<<EOF | grep -E "^STATUS"
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
```

Install Istio in both new clusters:
```bash
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

Check that the six Bookinfo workloads in each new cluster use HBONE
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  ./solo-istioctl zc workloads -n istio-system --context "${entry%%=*}" \
    | awk -v ctx="${entry%%=*}" '/^bookinfo/ { n++; if ($NF == "HBONE") h++ } END { print ctx ": " h+0 "/" n+0 " Bookinfo workloads on HBONE" }'
done
```

Expected output:
```
cluster3: 6/6 Bookinfo workloads on HBONE
cluster4: 6/6 Bookinfo workloads on HBONE
```

## Create the East-West Gateways

Install the `peering-eastwest` release in each new cluster, with the values from lab `007`. Every cluster uses the same three NodePorts, so the firewall rules you opened for cluster1 and cluster2 list the same ports for the new clusters:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  helm upgrade --install peering-eastwest oci://us-docker.pkg.dev/soloio-img/istio-helm/peering \
    --version $PEERING_CHART_VERSION-solo -n istio-gateways --create-namespace \
    --kube-context "${entry%%=*}" -f - <<EOF | grep -E "^STATUS"
eastwest:
  create: true
  cluster: ${entry#*=}
  network: ${entry#*=}
  serviceType: NodePort
  dataplaneServiceTypes: [nodeport]
  service:
    spec:
      ports:
      # Keep Istio's port names: Istio reads the protocol from the tls- prefix, and the chart requires hbone in one name
      - name: status-port
        port: 15021
        nodePort: $EW_STATUS_NODEPORT
      - name: tls-hbone
        port: 15008
        nodePort: $EW_HBONE_NODEPORT
      - name: tls-xds
        port: 15012
        nodePort: $EW_XDS_NODEPORT
remote:
  create: false
EOF
  for i in $(seq 1 30); do
    kubectl get deploy istio-eastwest -n istio-gateways --context "${entry%%=*}" &>/dev/null && break
    sleep 2
  done
  kubectl rollout status deploy/istio-eastwest -n istio-gateways --watch --timeout=90s --context "${entry%%=*}"
done
```

Check the Service in all four clusters
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  echo "${entry%%=*}: $(kubectl get svc istio-eastwest -n istio-gateways --context "${entry%%=*}" -o jsonpath='{.spec.type} {.spec.ports[*].nodePort}')"
done
```

Expected output:
```
cluster1: NodePort 31521 31508 31512
cluster2: NodePort 31521 31508 31512
cluster3: NodePort 31521 31508 31512
cluster4: NodePort 31521 31508 31512
```

> **A fixed port is already taken?** The Service fails to update if another Service in the cluster holds the port. `kubectl get svc -A --context <ctx> | grep <port>` finds the holder. Free the port in the new cluster: the remote peers in the other clusters expect the same xDS NodePort everywhere.

## Check Reachability Between Every Pair

Each direction between two clusters is a separate firewall path, and the four clusters have twelve. A gap in one direction shows up later as failover that works one way only. Check every direction before you peer.

Two kinds of address need to be open in each direction. istiod dials the peer's xDS address, the first node that matches `PEER_NODE_SELECTOR`, on the xDS NodePort. ztunnel sends HBONE to whichever peer node runs the east-west pod, and the pod can move to any node, so every peer node needs the HBONE NodePort open. The functions below list both:
```bash
peer_xds_ip() {
  kubectl get nodes -l "$PEER_NODE_SELECTOR" --context $1 \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}
peer_node_ips() {
  kubectl get nodes --context $1 -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
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

Probe the xDS NodePort of every peer's xDS address and the HBONE NodePort of every peer node, from every other cluster:
```bash
probe_port() {
  if kubectl exec reach-probe -n default --context $1 -- nc -z -w 3 $3 $4 2>/dev/null; then
    echo "OK    $1 -> $2 $3:$4"
  else
    echo "FAIL  $1 -> $2 $3:$4"
  fi
}
check_reach() {
  local SRC_CTX=$1 DST_CTX=$2 IP
  probe_port $SRC_CTX $DST_CTX "$(peer_xds_ip $DST_CTX)" $EW_XDS_NODEPORT
  for IP in $(peer_node_ips $DST_CTX); do
    probe_port $SRC_CTX $DST_CTX $IP $EW_HBONE_NODEPORT
  done
}

for src in "${ALL_CLUSTERS[@]}"; do
  for dst in "${ALL_CLUSTERS[@]}"; do
    [ "$src" = "$dst" ] && continue
    check_reach "${src%%=*}" "${dst%%=*}"
  done
done | grep -v '^OK' || echo "PASS: every peer node answers on the xDS and HBONE NodePorts"
```

Expected output:
```
PASS: every peer node answers on the xDS and HBONE NodePorts
```

The loop prints only the probes that failed. Fix every `FAIL` line before you peer: it names the source cluster, the destination node and the port to open.

## Peer the Four Clusters

Load `apply_remote_peers` from lab `007` and run it in every cluster. With four entries in `ALL_CLUSTERS`, each `peering-remote` release gets three remote peers: the releases in cluster1 and cluster2 gain two peers each, and cluster3 and cluster4 get new releases:
```bash
source peering/peering.sh
for entry in "${ALL_CLUSTERS[@]}"; do
  apply_remote_peers "${entry%%=*}"
done
```

Expected output (abridged; addresses differ on your machine):
```
istio-remote-peer-cluster2 in cluster1: xDS 172.30.0.4:31512
istio-remote-peer-cluster3 in cluster1: xDS 172.30.0.6:31512
istio-remote-peer-cluster4 in cluster1: xDS 172.30.0.8:31512
STATUS: deployed
istio-remote-peer-cluster1 in cluster2: xDS 172.30.0.2:31512
...
```

Wait for every remote peer to connect, and list them per cluster
```bash
for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    kubectl wait --for=condition=gloo.solo.io/PeerConnected gateway/istio-remote-peer-${peer#*=} -n istio-gateways \
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
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2,$KUBECONTEXT_CLUSTER3,$KUBECONTEXT_CLUSTER4" 2>&1 | grep -A3 "Peers Check" | grep -v "^--$"
```

Expected output (abridged; addresses differ on your machine):
```
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
     ✅ Connected to cluster3 via 172.30.0.6
     ✅ Connected to cluster4 via 172.30.0.8
✅ Peers Check: all clusters connected
     ✅ Connected to cluster1 via 172.30.0.2
     ✅ Connected to cluster3 via 172.30.0.6
     ✅ Connected to cluster4 via 172.30.0.8
...
```

## Apply the Policy Baseline on the New Clusters

cluster1 and cluster2 run the lab `008` baseline and the lab `009` waypoints. A new cluster starts with none of it, so any workload that shares the root CA can reach its Bookinfo pods. Apply the same baseline before the new clusters serve the global service. `auth-policy/strict-mtls.yaml` is the lab `008` PeerAuthentication and `bookinfo/waypoint.yaml` is the lab `009` waypoint:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  CTX=${entry%%=*}
  kubectl apply -f auth-policy/strict-mtls.yaml -f auth-policy/allow-nothing.yaml -f auth-policy/productpage-auth.yaml --context $CTX
  kubectl apply -f bookinfo/waypoint.yaml --context $CTX
  for i in $(seq 1 30); do
    kubectl get deploy waypoint -n bookinfo-backends --context $CTX &>/dev/null && break
    sleep 2
  done
  kubectl rollout status deploy/waypoint -n bookinfo-backends --watch --timeout=90s --context $CTX
  kubectl label namespace bookinfo-backends istio.io/use-waypoint=waypoint --overwrite --context $CTX
  kubectl apply -f auth-policy/waypoint-auth.yaml --context $CTX
done
```

These are the files cluster1 and cluster2 use, and their `principals` lists name only the `cluster1.local` and `cluster2.local` trust domains.

## Add the New Clusters to the Global Service

Label and annotate productpage in the new clusters, as lab `007` did in cluster1 and cluster2:
```bash
for entry in "${NEW_CLUSTERS[@]}"; do
  kubectl --context "${entry%%=*}" -n bookinfo-frontends label service productpage solo.io/service-scope=global --overwrite
  kubectl --context "${entry%%=*}" -n bookinfo-frontends annotate service productpage networking.istio.io/traffic-distribution=PreferNetwork --overwrite
done
for i in $(seq 1 15); do
  ./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -q "autogen.bookinfo-frontends.productpage .* 4/4" && break
  sleep 2
done
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen.bookinfo"
```

Expected output:
```
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     4/4
```

The global productpage in cluster1 now has four endpoints, one per cluster. List the network gateways that ztunnel in cluster1 knows, and the peer nodes behind them:
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NetworkGateway|autogen.node" | awk '{print $2, $3}'
```

Expected output (names and addresses differ on your machine):
```
NetworkGateway/cluster1/10.96.191.108/15008 10.96.191.108
NetworkGateway/cluster2/node.istio-eastwest.cluster2.mesh.internal/15008 node.istio-eastwest.cluster2.mesh.internal
NetworkGateway/cluster3/node.istio-eastwest.cluster3.mesh.internal/15008 node.istio-eastwest.cluster3.mesh.internal
NetworkGateway/cluster4/node.istio-eastwest.cluster4.mesh.internal/15008 node.istio-eastwest.cluster4.mesh.internal
autogen.node.cluster2.cluster2.4f489252 172.30.0.4
autogen.node.cluster3.cluster3.5d71fd96 172.30.0.6
autogen.node.cluster4.cluster4.70ee1a83 172.30.0.8
```

Each peer appears as a network gateway backed by the node that runs its east-west pod. ztunnel sends HBONE to that node on `31508`.

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

If you skipped labs `008` and `009`, every request returns a complete page. Skip to the step that scales productpage to zero in cluster2 and cluster3.

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

The cluster3 waypoint denied the call: `details-waypoint-auth` allows productpage only from `cluster1.local` and `cluster2.local`, and productpage in cluster3 runs as `cluster3.local/ns/bookinfo-frontends/sa/bookinfo-productpage`. Lab `008` lists trust domains on purpose, so every new cluster's trust domain must be added to every policy.

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
        - cluster1.local/ns/agentgateway-system/sa/ingress
        - cluster2.local/ns/agentgateway-system/sa/ingress
        - cluster3.local/ns/agentgateway-system/sa/ingress
        - cluster4.local/ns/agentgateway-system/sa/ingress
```

Apply the extended policies in all four clusters, so every cluster accepts the same identities:
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
for i in $(seq 1 15); do
  [ "$(curl -s http://$INGRESS_ADDR/productpage | grep -oE 'cluster[0-9]+' | head -1)" = cluster1 ] && break
  sleep 2
done
for i in $(seq 1 10); do
  curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[0-9]+|Error fetching product details" | head -1
done | sort | uniq -c
```

Expected output:
```
  10 cluster1
```

## Check Drift Across Every Pair

Run `check_peer_drift` from lab `013`, loaded from `peering/peering.sh`, for all twelve remote-peer Gateways. The loop prints only the Gateways that drifted:
```bash
source peering/peering.sh
for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    check_peer_drift "${local%%=*}" "${peer%%=*}" "${peer#*=}"
  done
done | grep -v '^OK' || echo "PASS: every remote-peer Gateway matches its peer"
```

Expected output:
```
PASS: every remote-peer Gateway matches its peer
```

Run this loop on a schedule. When the control-plane node of cluster3 is replaced, it reports `DRIFT` for three Gateways, one in each cluster that peers with cluster3, and the `apply_remote_peers` loop above repairs all three. Before an upgrade (lab `018`), run it for all twelve Gateways, then upgrade one cluster at a time.

## Cleanup

Remove the probe pods, and take cluster3 and cluster4 out of the mesh. Traffic already prefers cluster1. Uninstall their `peering-remote` releases, run `apply_remote_peers` in cluster1 and cluster2 with the two-cluster list, and put the two-cluster policies back in cluster1 and cluster2:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  kubectl delete pod reach-probe -n default --context "${entry%%=*}" --ignore-not-found
done
for entry in "${NEW_CLUSTERS[@]}"; do
  helm uninstall peering-remote -n istio-gateways --kube-context "${entry%%=*}"
done
ALL_CLUSTERS=("$KUBECONTEXT_CLUSTER1=$MESH_NAME_CLUSTER1" "$KUBECONTEXT_CLUSTER2=$MESH_NAME_CLUSTER2")
source peering/peering.sh
for entry in "${ALL_CLUSTERS[@]}"; do
  apply_remote_peers "${entry%%=*}"
done
for CTX in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply -f auth-policy/productpage-auth.yaml -f auth-policy/waypoint-auth.yaml --context $CTX
done
for i in $(seq 1 15); do
  ./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -q "autogen.bookinfo-frontends.productpage .* 2/2" && break
  sleep 2
done
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen.bookinfo"
```

Expected output:
```
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     2/2
```

The global productpage is back to two endpoints. Istio, Bookinfo and the `peering-eastwest` release stay installed on cluster3 and cluster4. Lab `020` removes them when you add the two contexts to its cluster list.

## Next Steps
At this point we have completed the following objectives:
- Installed Istio Ambient and Bookinfo on `cluster3` and `cluster4` with the shared root of trust
- Created the east-west gateways on the new clusters from the `peering` chart, with the same fixed NodePorts
- Checked xDS and HBONE NodePort reachability in all twelve directions between the four clusters
- Peered the four clusters in a full mesh with one loop
- Copied the policy baseline to the new clusters, and extended every policy to the four trust domains
- Failed productpage over across four clusters
- Ran the drift check for all twelve remote-peer Gateways

In the next step `020` we will remove everything this workshop created
