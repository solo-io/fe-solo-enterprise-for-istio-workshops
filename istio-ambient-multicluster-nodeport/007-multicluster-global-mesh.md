# Multicluster: Global Mesh over NodePort

# Objectives
- Install each cluster's east-west gateway from Solo's `peering` Helm chart, as a NodePort Service with fixed NodePorts
- Peer the two clusters with the same chart, pointing each remote peer at a node of the other cluster
- Configure a globally available service using labels (productpage)
- Reconfigure ingress to global service hostname (*.<namespace>.mesh.internal)
- Fail productpage over from cluster1 to cluster2 and back

![](../images/multicluster-global-mesh-agentgateway-1.png)

## Prerequisites
- This lab assumes you have completed setup from labs `000-006`
- `INGRESS_ADDR` from lab `006` is set in your shell. If you used the port-forward fallback, keep it running and keep `INGRESS_ADDR=localhost:8080`

## Set cluster contexts
In this workshop, you can use your preferred cluster context. To set it, run the following command, replacing cluster1 and cluster2 with your desired context name
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC

export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER2=cluster2    # Recommended to keep as cluster2 for POC
[ -n "$INGRESS_ADDR" ] || echo "WARNING: INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

The peering blocks below loop over a list of clusters. Each entry is `<kubectl context>=<mesh name>`. Lab `019` appends two clusters to this list:
```bash
ALL_CLUSTERS=("$KUBECONTEXT_CLUSTER1=$MESH_NAME_CLUSTER1" "$KUBECONTEXT_CLUSTER2=$MESH_NAME_CLUSTER2")
printf '%s\n' "${ALL_CLUSTERS[@]}"
```

Expected output:
```
cluster1=cluster1
cluster2=cluster2
```

## Background

Solo's `peering` Helm chart creates the two Gateways that peering needs, in two releases per cluster:

| Release | Gateway | Class | What it represents |
|---|---|---|---|
| `peering-eastwest` | `istio-eastwest` | `istio-eastwest` | The local east-west gateway. Its `NodePort` Service receives HBONE (`15008`) and xDS (`15012`) traffic from the peers on fixed NodePorts |
| `peering-remote` | `istio-remote-peer-<peer>` | `istio-remote` | One Gateway per peer cluster. Its address is a node InternalIP in the peer, and its `xds-tls` listener port is the peer's xDS NodePort |

istiod in each cluster connects to the peer's istiod through that address and the xDS NodePort, and the two exchange service and workload information. With the NodePort data plane, ztunnel sends cross-cluster HBONE to the peer nodes that run an east-west gateway pod, on the HBONE NodePort. Lab `013` shows what happens when that pod moves.

> **Versions.** This workshop installs the `1.29.7-patch0` peering chart on Istio `1.28.10-patch0`. The releases stay in place through the upgrade and rollback in lab `018`. The NodePort data plane is a beta feature of Solo Istio.

## Set the chart version and NodePorts

Every cluster uses the same three NodePorts. Each cluster has its own NodePort range, so the values can repeat across clusters, and your firewall rules open the same two ports, HBONE and xDS, toward every cluster. Pick values in the NodePort range (default `30000-32767`) that no other Service in the cluster holds:
```bash
export PEERING_CHART_VERSION=1.29.7-patch0
export EW_STATUS_NODEPORT=31521
export EW_HBONE_NODEPORT=31508
export EW_XDS_NODEPORT=31512
```

## Create the east-west gateways

Install the `peering-eastwest` release in each cluster, as a `NodePort` Service with the NodePort data plane and the three fixed NodePorts:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
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
      # Keep Istio's default port names
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
done
```

Expected output:
```
STATUS: deployed
STATUS: deployed
```

Istio creates the gateway Deployment from the Gateway a few seconds later. Wait for it in both clusters:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  for i in $(seq 1 30); do
    kubectl get deploy istio-eastwest -n istio-gateways --context "${entry%%=*}" &>/dev/null && break
    sleep 2
  done
  kubectl rollout status deploy/istio-eastwest -n istio-gateways --watch --timeout=90s --context "${entry%%=*}"
done
```

Check the Service in both clusters. A remote peer points at one node of the peer cluster, and kube-proxy on that node forwards the NodePort traffic to a gateway pod in the same cluster. That needs `externalTrafficPolicy: Cluster`, the default. With `Local`, a node without a gateway pod drops the traffic:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  echo "${entry%%=*}: $(kubectl get svc istio-eastwest -n istio-gateways --context "${entry%%=*}" --no-headers \
    -o custom-columns='TYPE:.spec.type,NODEPORTS:.spec.ports[*].nodePort,POLICY:.spec.externalTrafficPolicy')"
done
```

Expected output:
```
cluster1: NodePort   31521,31508,31512   Cluster
cluster2: NodePort   31521,31508,31512   Cluster
```

Both clusters serve HBONE on `31508` and xDS on `31512`. A recreated Service gets the same NodePorts.

> **A fixed port is already taken?** The Service fails to update if another Service in the cluster holds the port. `kubectl get svc -A --context <ctx> | grep <port>` finds the holder. Pick other values, export them, and run the install loop again.

## Peer the clusters over NodePort

A remote peer holds one address, a node InternalIP in the peer cluster. This workshop points each peer at the other cluster's control-plane node, because control-plane node IPs change less often than worker IPs. The nodes of each cluster must reach that node on the xDS NodePort, and every node of the peer on the HBONE NodePort:
```bash
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
```

`peering/peering.sh` defines `apply_remote_peers`. It installs the `peering-remote` release in one cluster, with one remote peer for every other cluster in `ALL_CLUSTERS`. Each peer's address is the InternalIP of the first peer node that matches `PEER_NODE_SELECTOR`. The Gateway name, trust domain and network come from the peer's mesh name. Load the file and print the function:
```bash
source peering/peering.sh
sed -n '/^apply_remote_peers()/,/^}/p' peering/peering.sh
```

Run it in every cluster:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  apply_remote_peers "${entry%%=*}"
done
```

Expected output (addresses differ on your machine):
```
istio-remote-peer-cluster2 in cluster1: xDS 172.30.0.4:31512
STATUS: deployed
istio-remote-peer-cluster1 in cluster2: xDS 172.30.0.2:31512
STATUS: deployed
```

The loop is safe to run again. A second run reads the peer addresses again and upgrades the releases in place.

> **Control-plane nodes out of reach?** On managed Kubernetes such as EKS, GKE and AKS, the control-plane nodes are missing from the node list, so the selector matches nothing and `apply_remote_peers` stops with `No node in <context> matches PEER_NODE_SELECTOR`. The same applies when a firewall closes the NodePort range on the control-plane nodes. Set `PEER_NODE_SELECTOR` to a label on a node pool whose nodes change rarely, such as a dedicated gateway pool, and run the loop again.

> **One address per peer.** If the peer node goes away, rerun `apply_remote_peers`. Lab `013` covers this.

Print the address, port and listener of the remote peer in cluster1:
```bash
kubectl get gateway istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{.spec.addresses[0].value}:{.spec.listeners[*].port} {.spec.listeners[*].name}{"\n"}'
```

Expected output (the address differs on your machine):
```
172.30.0.4:31512 xds-tls
```

The address is the cluster2 control-plane node, and the port is the cluster2 xDS NodePort. The Gateway has only the `xds-tls` listener. With the NodePort data plane, ztunnel takes the HBONE addresses from the node list that the peer's istiod sends.

## Verify the peering

Wait until both remote peers report a working peering, then list their conditions. Solo's peering controller adds three conditions to each remote-peer Gateway: `PeerConnected` for the xDS link, `PeeringSucceeded` for the first sync, and `PeerDataPlaneProgrammed` for the NodePort data plane:
```bash
kubectl wait --for=condition=gloo.solo.io/PeerDataPlaneProgrammed gateway/istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=gloo.solo.io/PeerDataPlaneProgrammed gateway/istio-remote-peer-$MESH_NAME_CLUSTER1 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER2
kubectl get gateway istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

Expected output:
```
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster2 condition met
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster1 condition met
Accepted=True Resource accepted
Programmed=True This Gateway is remote; Istio will not program it
gloo.solo.io/PeerConnected=True 
gloo.solo.io/PeeringSucceeded=True 
gloo.solo.io/PeerDataPlaneProgrammed=True peering data plane programmed for cross-network traffic with NodePort service type
```

Check the peering from both sides
```bash
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2"
```

Expected output (abridged):
```
✅ Gateway Check: all eastwest gateways programmed
     ✅ istio-gateways/istio-eastwest available at 10.105.232.25
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
```

The check reports the ClusterIP of the `istio-eastwest` Service. Peers connect through the node IP and xDS NodePort in their `istio-remote-peer-<peer>` Gateway.

## Configure a global service

Label and annotate the `productpage` Service in each cluster:

- `solo.io/service-scope=global`: Istio generates a `ServiceEntry` in each cluster with the hostname `<service>.<namespace>.mesh.internal`. Workloads in either cluster reach the service through that hostname, whichever cluster runs it.
- `networking.istio.io/traffic-distribution=PreferNetwork`: Istio sends traffic to instances in the local network (the local cluster) and fails over to the remote cluster when no healthy local instance is left.

```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl --context ${context} -n bookinfo-frontends label service productpage solo.io/service-scope=global --overwrite
  kubectl --context ${context} -n bookinfo-frontends annotate service productpage networking.istio.io/traffic-distribution=PreferNetwork --overwrite
done
```

Check the generated ServiceEntry in each cluster:
```bash
for CTX in "$KUBECONTEXT_CLUSTER1" "$KUBECONTEXT_CLUSTER2"; do
  echo "Checking for autogen global ServiceEntry in $CTX"
  kubectl --context $CTX get serviceentry -n istio-system
done
```

Expected output:
```
Checking for autogen global ServiceEntry in cluster1
NAME                                      HOSTS                                              LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage    ["productpage.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       5s
autogen.peering.istio-eastwest.cluster2   ["node.istio-eastwest.cluster2.mesh.internal"]     MESH_INTERNAL   STATIC       8s
Checking for autogen global ServiceEntry in cluster2
NAME                                      HOSTS                                              LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage    ["productpage.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       5s
autogen.peering.istio-eastwest.cluster1   ["node.istio-eastwest.cluster1.mesh.internal"]     MESH_INTERNAL   STATIC       7s
```

`autogen.peering.istio-eastwest.<peer>` comes from the NodePort data plane: it is the hostname of the peer's east-west gateway nodes.

ztunnel in cluster1 now knows a network gateway for cluster2. Its address is a hostname, `node.istio-eastwest.cluster2.mesh.internal`, and the workloads behind it are the cluster2 nodes that run an east-west gateway pod. istiod generates one entry per node from what cluster2 reports
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|NetworkGateway/$MESH_NAME_CLUSTER2|autogen.node.$MESH_NAME_CLUSTER2"
kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest --context $KUBECONTEXT_CLUSTER2 \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.hostIP}{"\n"}{end}'
```

Expected output (names and addresses differ on your machine):
```
NAMESPACE           POD NAME                                                                 ADDRESS                                    NODE     WAYPOINT PROTOCOL
istio-gateways      NetworkGateway/cluster2/node.istio-eastwest.cluster2.mesh.internal/15008 node.istio-eastwest.cluster2.mesh.internal          None     TCP
istio-gateways      autogen.node.cluster2.cluster2.4f489252                                  172.30.0.4                                          None     TCP
istio-eastwest-58c688b6f8-fqvqd cluster2 172.30.0.4
```

ztunnel in cluster1 sends HBONE for cluster2 to `172.30.0.4`, the node that runs the cluster2 east-west pod, on the HBONE NodePort `31508`. Here the east-west pod runs on the control-plane node, so the HBONE and xDS addresses match. When the pod runs on a worker, they differ.

## Configure Ingress Gateway in cluster1 to route to the global service

Reconfigure the bookinfo application to use the global service hostname `*.<namespace>.mesh.internal`
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-route
  namespace: bookinfo-frontends
spec:
  parentRefs:
    - name: ingress
      namespace: agentgateway-system
  rules:
    - matches:
      - path:
          type: PathPrefix
          value: /
      backendRefs:
      - kind: Hostname
        group: networking.istio.io
        name: productpage.bookinfo-frontends.mesh.internal
        port: 9080
EOF
```

Send a request through the ingress gateway and check which cluster served the reviews
```bash
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster1
```

cluster1 served the request. The Reviews section of the productpage in a browser also shows `cluster1`, because lab `001` set the `CLUSTER_NAME` environment variable on the reviews deployments.

## Failover productpage on cluster1

Scale down productpage-v1 in the `bookinfo-frontends` namespace on cluster1
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
```

Send the request again. The ingress gateway in cluster1 now reaches productpage in cluster2 over the HBONE NodePort
```bash
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster2
```

Tail logs of ztunnel on `cluster2` in a new terminal to watch the connections arrive
```bash
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER2 -f --prefix | grep "mesh.internal"
```

Expected output (one line per connection, written when the connection closes):
```
[pod/ztunnel-xh9gv/istio-proxy] 2026-10-13T19:09:16.931151Z	info	access	connection complete	src.addr=10.244.1.30:38350 src.workload="ingress" src.namespace="agentgateway-system" src.identity="spiffe://cluster1.local/ns/agentgateway-system/sa/ingress" dst.addr=10.244.1.18:15008 dst.hbone_addr=productpage.bookinfo-frontends.mesh.internal:9080 dst.service="productpage.bookinfo-frontends.mesh.internal" dst.workload="productpage-v1-59c74584cf-cx892" dst.namespace="bookinfo-frontends" dst.identity="spiffe://cluster2.local/ns/bookinfo-frontends/sa/bookinfo-productpage" direction="inbound" bytes_sent=9739 bytes_recv=119 duration="2314ms"
```

In the log line, `src.identity` is the agentgateway ingress gateway in cluster1 (`cluster1.local` trust domain) and `dst.identity` is productpage in cluster2 (`cluster2.local`). The request crossed clusters over mTLS, and each side kept its own trust domain. `dst.service` is the global hostname `productpage.bookinfo-frontends.mesh.internal`. agentgateway keeps its HBONE connection to productpage open across requests, so ztunnel logs one line per connection instead of one per request.

## Restore productpage on cluster1

Scale productpage-v1 back up in the `bookinfo-frontends` namespace on cluster1
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 1 --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

Send the request again. With a healthy local instance, `PreferNetwork` routes traffic back to cluster1, and the ztunnel log in cluster2 goes quiet. The loop waits up to 30 seconds for the new pod to become ready in the mesh:
```bash
for i in $(seq 1 15); do
  curl -s http://$INGRESS_ADDR/productpage | grep -q cluster1 && break
  sleep 2
done
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster1
```

## Next Steps
At this point we have completed the following objectives
- Installed each cluster's east-west gateway from the `peering` Helm chart, as a NodePort Service with fixed NodePorts
- Peered the two clusters with the same chart, pointing each remote peer at a node of the other cluster
- Configured a globally available service using labels (productpage)
- Reconfigured ingress to the global service hostname
- Failed productpage over from cluster1 to cluster2 and back

In the next step `008` we will lock down the mesh with identity-based policies in both clusters, and quarantine a workload
