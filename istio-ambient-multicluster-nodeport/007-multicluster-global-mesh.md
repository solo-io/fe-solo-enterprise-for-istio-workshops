# Multicluster: Global Mesh over NodePort

# Objectives
- Expose each cluster's east-west gateway as a NodePort Service
- Peer the two clusters by pointing each remote peer at the other cluster's node IPs and NodePorts
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
[ -n "$INGRESS_ADDR" ] || echo "⚠️  INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

## Background

Each cluster holds two Gateways for peering:

| Gateway | Class | What it represents |
|---|---|---|
| `istio-eastwest` | `istio-eastwest` | The local east-west gateway. A `NodePort` Service receives HBONE (`15008`) and xDS (`15012`) traffic from the peer cluster |
| `istio-remote-peer-<peer>` | `istio-remote` | The peer cluster. Its addresses are the peer's node InternalIPs, and its listener ports are the peer's two NodePorts |

istiod in each cluster connects to the peer's istiod through the `xds-tls` listener to exchange service and workload information. ztunnel sends cross-cluster requests as HBONE to the `cross-network` listener. Both listeners use node IPs and NodePorts.

> **Why not `solo-istioctl multicluster link`?** In 1.28, `link` reads the peer address from a LoadBalancer on the east-west gateway. With a NodePort Service it stops with `services found with "istio.io/expose-istiod" label, but none have a load balancer`. This lab writes the same `istio-remote-peer-<peer>` Gateways with `kubectl` instead.

> **Note:** Solo also documents a native NodePort mode (`--data-plane-service-types nodeport` on `expose`). It is beta, it sends only the HBONE data plane over NodePorts, and it still needs a stable LoadBalancer address for xDS on `15012`. Consider it when your clusters have a LoadBalancer for the control plane. See [LoadBalancer vs NodePort for east-west and peering gateways](https://docs.solo.io/istio/1.30.x/ambient/multicluster/best-practices/peering-recs/).

## Create the east-west gateways

Create the istio-gateways namespace
```bash
kubectl create ns istio-gateways --context $KUBECONTEXT_CLUSTER1 --dry-run=client -o yaml | kubectl apply --context $KUBECONTEXT_CLUSTER1 -f -
kubectl create ns istio-gateways --context $KUBECONTEXT_CLUSTER2 --dry-run=client -o yaml | kubectl apply --context $KUBECONTEXT_CLUSTER2 -f -
```

Use Solo `istioctl` to generate the east-west gateways, and add the `networking.istio.io/service-type: NodePort` annotation before you apply them. The annotation makes Istio create the `istio-eastwest` Service as a `NodePort`. Without the annotation, `expose` creates a `LoadBalancer` Service, and a cluster with a load balancer controller then provisions a cloud load balancer for the istiod and HBONE ports.
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  ./solo-istioctl multicluster expose --namespace istio-gateways --context $context --generate \
    | kubectl annotate --local -f - networking.istio.io/service-type=NodePort -o yaml \
    | kubectl apply --context $context -f -
done
```

> **Already ran plain `expose` without the annotation?** Add the annotation to the existing Gateway in each cluster. Istio changes the Service to `NodePort` in place and keeps its NodePorts:
> ```bash
> kubectl annotate gateway istio-eastwest -n istio-gateways networking.istio.io/service-type=NodePort --overwrite --context $KUBECONTEXT_CLUSTER1
> ```

Wait for the east-west gateways to be deployed
```bash
for deploy in $(kubectl get deploy -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "Waiting for e/w gateway deployment '$deploy' to be ready in $KUBECONTEXT_CLUSTER1..."
  kubectl rollout status deploy/"$deploy" -n istio-gateways --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
  done

for deploy in $(kubectl get deploy -n istio-gateways --context $KUBECONTEXT_CLUSTER2 -o jsonpath='{.items[*].metadata.name}'); do
  echo "Waiting for e/w gateway deployment '$deploy' to be ready in $KUBECONTEXT_CLUSTER2..."
  kubectl rollout status deploy/"$deploy" -n istio-gateways --watch --timeout=90s --context $KUBECONTEXT_CLUSTER2
  done
```

Check that the Service type is `NodePort` in both clusters
```bash
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER2
```

Expected output (IPs and NodePorts differ on your machine):
```
NAME             TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                                           AGE
istio-eastwest   NodePort   10.105.232.25   <none>        15021:30566/TCP,15008:30224/TCP,15012:32326/TCP   18s
NAME             TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                                           AGE
istio-eastwest   NodePort   10.102.83.177   <none>        15021:30104/TCP,15008:32220/TCP,15012:32597/TCP   18s
```

Each cluster now has a NodePort for HBONE (`15008`) and one for xDS (`15012`). In this example cluster2 serves HBONE on `32220` and xDS on `32597`.

## Peer the clusters over NodePort

A remote-peer Gateway holds node IPs, so it goes stale when a listed node is replaced. This workshop points each peer at the other cluster's control-plane nodes. The east-west gateway pods stay on the workers. kube-proxy on each control-plane node forwards the NodePort traffic to a gateway pod in the same cluster, like an L3 proxy. This works because `svc/istio-eastwest` uses `externalTrafficPolicy: Cluster`, the default. With `Local`, a node without a gateway pod drops the traffic. Check the policy in each cluster:
```bash
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER2 -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
```

Expected output:
```
Cluster
Cluster
```

Select the control-plane nodes as the peer addresses. The nodes of each cluster must reach the other cluster's control-plane nodes on the NodePort range:
```bash
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
```

> **Note:** Peering with `PEER_NODE_SELECTOR` set has proven more stable in deployments of this NodePort architecture, because control-plane node IPs change less often than worker IPs. An east-west gateway rollout that moves the pod to another node also leaves the peer addresses valid.

The function below applies the `istio-remote-peer-<peer>` Gateway for one direction. Its addresses are the InternalIPs of the peer nodes that match `PEER_NODE_SELECTOR`. The Gateway name, trust domain and network come from the peer's mesh name, not from its kubectl context.

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

apply_remote_peer $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
apply_remote_peer $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

The block is safe to run again. A second run updates the Gateways in place.

> **Control-plane nodes out of reach?** On managed Kubernetes such as EKS, GKE and AKS, the control-plane nodes are missing from the node list, so the selector matches nothing and `apply_remote_peer` stops with `No istio-eastwest NodePorts or peer node addresses found`. The same applies when a firewall closes the NodePort range on the control-plane nodes. Unset the selector and run the two `apply_remote_peer` lines again. The peer addresses then default to the nodes that host a running `istio-eastwest` pod, skipping pods still terminating after a rollout. kube-proxy delivers to a gateway pod on the same node, so the extra node hop goes away. Those addresses change when the pod moves to another node, so run the two lines again after each east-west gateway rollout:
> ```bash
> unset PEER_NODE_SELECTOR
> apply_remote_peer $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
> apply_remote_peer $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
> ```

Look at the result in cluster1
```bash
kubectl get gateway istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o yaml
```

Expected output (abridged; IPs and NodePorts differ on your machine):
```
metadata:
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: cluster2.local
  labels:
    topology.istio.io/cluster: cluster2
    topology.istio.io/network: cluster2
  name: istio-remote-peer-cluster2
  namespace: istio-gateways
spec:
  addresses:
  - type: IPAddress
    value: 172.30.0.4               # <-- cluster2 control-plane node (PEER_NODE_SELECTOR)
  gatewayClassName: istio-remote
  listeners:
  - allowedRoutes:
      namespaces:
        from: Same
    name: cross-network
    port: 32220                     # <-- cluster2 NodePort for HBONE (15008)
    protocol: HBONE
    tls:
      mode: Passthrough
  - allowedRoutes:
      namespaces:
        from: Same
    name: xds-tls
    port: 32597                     # <-- cluster2 NodePort for xDS (15012)
    protocol: TLS
    tls:
      mode: Passthrough
```

> **Node IPs and NodePorts are read once.** If a listed peer node is replaced, or `svc/istio-eastwest` is recreated with new NodePorts, run the `apply_remote_peer` block again. Lab `013` detects both kinds of drift.

## Verify the peering

Wait for both remote-peer Gateways to be programmed
```bash
kubectl wait --for=condition=Programmed gateway/istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Programmed gateway/istio-remote-peer-$MESH_NAME_CLUSTER1 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER2
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

The check reports the ClusterIP of the `istio-eastwest` Service. Peers connect through the node IP and NodePort in their `istio-remote-peer-<peer>` Gateway.

Confirm in the istiod logs that each cluster finished its first sync with the peer
```bash
kubectl logs -n istio-system deploy/istiod --context $KUBECONTEXT_CLUSTER1 | grep "sync complete" | grep "network=$MESH_NAME_CLUSTER2"
kubectl logs -n istio-system deploy/istiod --context $KUBECONTEXT_CLUSTER2 | grep "sync complete" | grep "network=$MESH_NAME_CLUSTER1"
```

Expected output (one block per cluster):
```
2026-10-12T16:19:57.060028Z	info	peering	XDS sync complete, waiting for segment info...	cluster=cluster2 network=cluster2 mode=gateway
2026-10-12T16:19:57.060038Z	info	peering	cluster cluster2 sync complete	cluster=cluster2 network=cluster2 mode=gateway
```

## Configure a global service

Label and annotate the `productpage` Service in each cluster:

- `solo.io/service-scope=global`: Istio generates a `ServiceEntry` in each cluster with the hostname `<service>.<namespace>.mesh.internal`. Workloads in either cluster reach the service through that hostname, whichever cluster runs it.
- `networking.istio.io/traffic-distribution=PreferNetwork`: Istio sends traffic to instances in the local network (the local cluster) and fails over to the remote cluster when no healthy local instance is left.

```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl --context ${context}  -n bookinfo-frontends label service productpage solo.io/service-scope=global --overwrite
  kubectl --context ${context}  -n bookinfo-frontends annotate service productpage  networking.istio.io/traffic-distribution=PreferNetwork --overwrite
done
```

We should now see an automatically generated ServiceEntry referencing our global service in each cluster
```bash
for CTX in "$KUBECONTEXT_CLUSTER1" "$KUBECONTEXT_CLUSTER2"; do
  echo "Checking for autogen global ServiceEntry in $CTX"
  kubectl --context $CTX get serviceentry -n istio-system
done
```

Expected output:
```
Checking for autogen global ServiceEntry in cluster1
NAME                                     HOSTS                                              LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage   ["productpage.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       5s
Checking for autogen global ServiceEntry in cluster2
NAME                                     HOSTS                                              LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage   ["productpage.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       5s
```

ztunnel in cluster1 now knows a network gateway for cluster2. Its address is the cluster2 node IP and HBONE NodePort from the remote-peer Gateway
```bash
./solo-istioctl zc all -n istio-system --context $KUBECONTEXT_CLUSTER1 -o json | grep -o "\"NetworkGateway/$MESH_NAME_CLUSTER2/[^\"]*\"" | sort -u
```

Expected output:
```
"NetworkGateway/cluster2/172.30.0.4/32220"
```

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
curl -s http://$INGRESS_ADDR/productpage -o /dev/null -w "%{http_code}\n"
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]" | sort | uniq -c
```

Expected output:
```
200
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

Send the request again. With a healthy local instance, `PreferNetwork` routes traffic back to cluster1, and the ztunnel log in cluster2 goes quiet. If you still see `cluster2`, wait a few seconds for the new pod to become ready in the mesh and retry
```bash
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster1
```

## Next Steps
At this point we have completed the following objectives
- Exposed each cluster's east-west gateway as a NodePort Service
- Peered the two clusters by pointing each remote peer at the other cluster's node IPs and NodePorts
- Configured a globally available service using labels (productpage)
- Reconfigured ingress to the global service hostname
- Failed productpage over from cluster1 to cluster2 and back

In the next step `008` we will lock down the mesh with identity-based policies in both clusters, and quarantine a workload
