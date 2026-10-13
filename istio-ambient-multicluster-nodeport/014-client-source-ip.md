# Carry the Real Client IP Through the Ingress Gateway

# Objectives
- See which client address the ingress gateway records with `externalTrafficPolicy: Cluster` and with `Local`
- Accept PROXY protocol from a load balancer, so the gateway records the client behind it
- Follow the client IP from the gateway to a backend in the same cluster and in the peer cluster
- Record the client IP in the gateway access log for observability tools

## Prerequisites
- This lab assumes you have completed setup from labs `000-013`

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
```

## Background

A request from outside the cluster passes through up to three components that can replace its source address before the ingress gateway sees it:

| Component | What it does to the source address | How to keep the client address |
|---|---|---|
| External load balancer (hardware, or cloud) | A proxying load balancer opens a new connection, so the source becomes the load balancer | PROXY protocol: the load balancer sends the client address in a header at the start of the connection |
| kube-proxy, for a `NodePort` or `LoadBalancer` Service | `externalTrafficPolicy: Cluster` can forward to a pod on any node, and SNATs the connection | `externalTrafficPolicy: Local`: only nodes with a gateway pod accept traffic, and kube-proxy keeps the source |
| The ingress gateway | Terminates the client connection and opens a new one to the backend | The gateway writes the client address into `X-Forwarded-For` and `X-Envoy-External-Address` |

After the gateway, the backend's L4 source is always the gateway, or the peer cluster's east-west gateway for a cross-cluster call. The client IP reaches the backend as an HTTP header, and it reaches observability tools through the gateway's access log.

This lab uses a separate `ingress-edge` Gateway with a `NodePort` Service, so the changes do not affect the `ingress` Gateway that the other labs use. A namespace `outside` in cluster2, outside the mesh, plays the external side:

| Pod in cluster2 `outside` | Plays the role of |
|---|---|
| `client` | A client on the network outside cluster1. cluster2 SNATs its traffic to its node IP when it leaves the cluster, so from cluster1's side the client address is that node IP |
| `haproxy` | A load balancer that sends PROXY protocol v2. It reaches `client` directly inside cluster2, so the address it forwards is the client pod IP |

The backend is the Istio `echo` test app, which prints the request headers and the source address it saw. It runs in both clusters behind the global hostname `echo.client-ip.mesh.internal`.

## Deploy the Backend and the Edge Gateway

Deploy `echo` in both clusters. Each copy reports its cluster name:
```bash
for N in 1 2; do
  CONTEXT=$(eval echo \$KUBECONTEXT_CLUSTER$N)
  kubectl apply --context $CONTEXT -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: client-ip
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: client-ip
spec:
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: docker.io/istio/app:1.28.10
        args: ["--port", "8080", "--cluster", "cluster$N"]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: client-ip
  labels:
    solo.io/service-scope: global
  annotations:
    networking.istio.io/traffic-distribution: PreferNetwork
spec:
  selector:
    app: echo
  ports:
  - name: http
    port: 8080
EOF
  kubectl rollout status deploy/echo -n client-ip --watch --timeout=120s --context $CONTEXT
done
```

Create the `ingress-edge` Gateway in cluster1 and route it to the global `echo` hostname:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress-edge
  namespace: istio-system
  annotations:
    networking.istio.io/service-type: NodePort
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: client-ip
spec:
  parentRefs:
  - name: ingress-edge
    namespace: istio-system
  rules:
  - backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: echo.client-ip.mesh.internal
      port: 8080
EOF
kubectl rollout status deploy/ingress-edge-istio -n istio-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
```

Deploy the external client in cluster2:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER2 -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: outside
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: outside
spec:
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.22.0
        command: ["sleep", "infinity"]
EOF
kubectl rollout status deploy/client -n outside --watch --timeout=120s --context $KUBECONTEXT_CLUSTER2
```

Read the addresses this lab uses: the edge NodePort, the cluster1 node that runs the edge gateway, the other cluster1 node, and the client's own addresses:
```bash
export EDGE_PORT=$(kubectl get svc ingress-edge-istio -n istio-system --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
export GATEWAY_NODE_IP=$(kubectl get pod -n istio-system -l gateway.networking.k8s.io/gateway-name=ingress-edge \
  --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].status.hostIP}')
export OTHER_NODE_IP=$(kubectl get nodes --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | grep -v "^$GATEWAY_NODE_IP$" | head -1)
kubectl get pod -n outside -l app=client --context $KUBECONTEXT_CLUSTER2 \
  -o jsonpath='client pod IP {.items[0].status.podIP}, client node IP {.items[0].status.hostIP}{"\n"}'
echo "edge NodePort $EDGE_PORT, gateway node $GATEWAY_NODE_IP, other node $OTHER_NODE_IP"
```

Expected output (addresses differ on your machine):
```
client pod IP 10.244.2.74, client node IP 172.30.0.5
edge NodePort 32562, gateway node 172.30.0.3, other node 172.30.0.2
```

Define a helper that sends a request from the client and prints the fields that matter. `IP` is the source address the `echo` pod saw:
```bash
call_edge() {
  kubectl exec deploy/client -n outside --context $KUBECONTEXT_CLUSTER2 -- curl -s -m 5 "$1" \
    | grep -E "^Cluster=|^IP=|X-Forwarded-For" || echo "no response"
}
```

## With externalTrafficPolicy Cluster

The Service starts with the Kubernetes default, `externalTrafficPolicy: Cluster`. Send a request to each cluster1 node:
```bash
echo "== via the gateway's node"; call_edge http://$GATEWAY_NODE_IP:$EDGE_PORT/
echo "== via the other node";     call_edge http://$OTHER_NODE_IP:$EDGE_PORT/
```

Expected output:
```
== via the gateway's node
Cluster=cluster1
IP=10.244.2.120
RequestHeader=X-Forwarded-For:10.244.2.1
== via the other node
Cluster=cluster1
IP=10.244.2.120
RequestHeader=X-Forwarded-For:10.244.0.0
```

`X-Forwarded-For` should hold the client address, `172.30.0.5`. It holds an address inside cluster1 instead: the pod bridge on the gateway's node (`10.244.2.1`), or the overlay address of the other node (`10.244.0.0`). kube-proxy SNATs NodePort traffic under `Cluster`, so the gateway never sees the client. `IP=10.244.2.120` is the edge gateway pod: the backend's L4 source is the gateway in every case.

## With externalTrafficPolicy Local

Istio builds the gateway's Service from the Gateway resource. A ConfigMap referenced in `spec.infrastructure.parametersRef` overlays fields on that Service:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-edge-options
  namespace: istio-system
data:
  service: |
    spec:
      externalTrafficPolicy: Local
EOF
kubectl patch gateway ingress-edge -n istio-system --context $KUBECONTEXT_CLUSTER1 --type=merge \
  -p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"ingress-edge-options"}}}}'
sleep 3
kubectl get svc ingress-edge-istio -n istio-system --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
echo "== via the gateway's node"; call_edge http://$GATEWAY_NODE_IP:$EDGE_PORT/
echo "== via the other node";     call_edge http://$OTHER_NODE_IP:$EDGE_PORT/
```

Expected output:
```
Local
== via the gateway's node
Cluster=cluster1
IP=10.244.2.120
RequestHeader=X-Forwarded-For:172.30.0.5
== via the other node
no response
```

The gateway now records the client address, `172.30.0.5`. The other node has no gateway pod, so under `Local` it drops the connection. Whatever sends traffic to the NodePorts must use only nodes with a gateway pod: a cloud load balancer does this through the Service's `healthCheckNodePort`, and a hardware load balancer needs a health check on the same port.

## Accept PROXY Protocol from a Load Balancer

A proxying load balancer, such as a hardware load balancer in proxy mode or a cloud load balancer that terminates connections, replaces the client address with its own. PROXY protocol carries the original address in a header at the start of each connection. Turn it on for the edge gateway with the `gatewayTopology.proxyProtocol` proxy setting, added to the gateway pods through the same ConfigMap:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-edge-options
  namespace: istio-system
data:
  service: |
    spec:
      externalTrafficPolicy: Local
  deployment: |
    spec:
      template:
        metadata:
          annotations:
            proxy.istio.io/config: |
              gatewayTopology:
                proxyProtocol: {}
EOF
sleep 3
kubectl rollout status deploy/ingress-edge-istio -n istio-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
export GATEWAY_NODE_IP=$(kubectl get pod -n istio-system -l gateway.networking.k8s.io/gateway-name=ingress-edge \
  --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].status.hostIP}')
```

Deploy haproxy in cluster2 as the load balancer. It accepts plain TCP on port `8080` and opens each connection to the edge gateway with a PROXY protocol v2 header:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER2 -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: haproxy
  namespace: outside
data:
  haproxy.cfg: |
    defaults
      mode tcp
      timeout connect 5s
      timeout client 30s
      timeout server 30s
    frontend edge
      bind :8080
      default_backend cluster1-ingress
    backend cluster1-ingress
      server gateway $GATEWAY_NODE_IP:$EDGE_PORT send-proxy-v2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: haproxy
  namespace: outside
spec:
  selector:
    matchLabels:
      app: haproxy
  template:
    metadata:
      labels:
        app: haproxy
    spec:
      containers:
      - name: haproxy
        image: haproxy:3.2.23-alpine
        volumeMounts:
        - name: config
          mountPath: /usr/local/etc/haproxy
      volumes:
      - name: config
        configMap:
          name: haproxy
---
apiVersion: v1
kind: Service
metadata:
  name: haproxy
  namespace: outside
spec:
  selector:
    app: haproxy
  ports:
  - port: 8080
EOF
kubectl rollout status deploy/haproxy -n outside --watch --timeout=120s --context $KUBECONTEXT_CLUSTER2
for i in $(seq 1 15); do
  kubectl exec deploy/client -n outside --context $KUBECONTEXT_CLUSTER2 -- curl -s -m 3 -o /dev/null http://haproxy:8080/ 2>/dev/null && break
  sleep 2
done
```

The loop waits until haproxy accepts connections, for up to 30 seconds. Call the gateway through haproxy, then directly:
```bash
echo "== through haproxy (PROXY protocol)"; call_edge http://haproxy:8080/
echo "== direct (no PROXY header)";         call_edge http://$GATEWAY_NODE_IP:$EDGE_PORT/
```

Expected output:
```
== through haproxy (PROXY protocol)
Cluster=cluster1
IP=10.244.2.120
RequestHeader=X-Forwarded-For:10.244.2.74
== direct (no PROXY header)
no response
```

`X-Forwarded-For` is now `10.244.2.74`, the client pod IP. haproxy saw the client before any SNAT and passed that address in the PROXY header. The direct request fails, because a listener with PROXY protocol requires the header on every connection. Put every client of a PROXY protocol gateway behind the load balancer, and keep a separate gateway for clients that connect directly.

> **If the load balancer sends `X-Forwarded-For` instead.** An L7 load balancer that terminates HTTP adds the client to `X-Forwarded-For` rather than using PROXY protocol. Tell the gateway how many proxies to trust with `gatewayTopology.numTrustedProxies` in the same `proxy.istio.io/config` annotation, so it reads the client address from the right position in the header.

## Follow the Client IP Across Clusters

Record the client address at the gateway. Turn on access logging for `ingress-edge`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: ingress-edge-access-logging
  namespace: istio-system
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: ingress-edge
  accessLogging:
  - providers:
    - name: envoy
EOF
sleep 3
```

Scale `echo` to zero in cluster1, so the gateway fails over to cluster2, and call it through haproxy:
```bash
kubectl scale deploy/echo -n client-ip --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=echo -n client-ip --timeout=60s --context $KUBECONTEXT_CLUSTER1
sleep 3
call_edge http://haproxy:8080/
sleep 2
kubectl logs deploy/ingress-edge-istio -n istio-system --context $KUBECONTEXT_CLUSTER1 --since=1m | tail -1
```

Expected output:
```
Cluster=cluster2
IP=10.244.2.56
RequestHeader=X-Forwarded-For:10.244.2.74
[2026-10-13T00:12:53.937Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 518 10 9 "10.244.2.74" "curl/8.22.0" "c0c0546d-e1f7-4677-9ecb-8e0777e28564" "haproxy:8080" "envoy://connect_network_originate_inner/echo.client-ip.mesh.internal:8080/172.30.0.4" outbound|8080||echo.client-ip.mesh.internal envoy://internal_client_address/ 10.244.2.75:8080 10.244.2.74:49588 - client-ip.echo.0
```

cluster2 served the request. Its L4 source, `IP=10.244.2.56`, is the cluster2 east-west gateway, and `X-Forwarded-For` still carries the client, `10.244.2.74`. In the access log, `"10.244.2.74"` is the `X-Forwarded-For` value and `10.244.2.74:49588` is the downstream address that the gateway read from the PROXY header. Ship these logs to your log pipeline to report client addresses per request.

Bring `echo` back in cluster1:
```bash
kubectl scale deploy/echo -n client-ip --replicas 1 --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/echo -n client-ip --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

## On-Premises and Cloud

| Environment | Load balancer in front of the gateway | Settings that keep the client address |
|---|---|---|
| On-premises, hardware load balancer in proxy mode | Opens a new connection per client | PROXY protocol on the load balancer and `gatewayTopology.proxyProtocol` on the gateway, as above. `externalTrafficPolicy: Local` if the load balancer targets NodePorts |
| On-premises, L3/L4 load balancer that keeps the source (for example BGP or ECMP to the nodes) | Forwards packets with the client source | `externalTrafficPolicy: Local` only |
| AWS Network Load Balancer | Keeps the source for instance targets, or sends PROXY protocol v2 when you turn it on for the target group | `externalTrafficPolicy: Local`, or PROXY protocol on both sides |
| Azure Standard Load Balancer | Forwards packets with the client source | `externalTrafficPolicy: Local` |
| Any L7 load balancer that terminates HTTP | Adds `X-Forwarded-For` | `gatewayTopology.numTrustedProxies` |

The steps after the gateway are the same everywhere: the client IP travels in `X-Forwarded-For` to the backend, in the same cluster or across clusters, and the gateway access log records it. Confirm the load balancer behavior for your own load balancer models and settings with the same `call_edge` test.

## Cleanup

Remove the edge gateway, its options and access logging, the `echo` backend and the `outside` namespace:
```bash
kubectl delete telemetry ingress-edge-access-logging -n istio-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete httproute echo -n client-ip --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete gateway ingress-edge -n istio-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete configmap ingress-edge-options -n istio-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace client-ip --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace client-ip outside --context $KUBECONTEXT_CLUSTER2 --ignore-not-found
```

## Next Steps
At this point we have completed the following objectives:
- Saw which client address the ingress gateway recorded with `externalTrafficPolicy: Cluster` and with `Local`
- Accepted PROXY protocol from a load balancer, so the gateway recorded the client behind it
- Followed the client IP from the gateway to a backend in the same cluster and in the peer cluster
- Recorded the client IP in the gateway access log for observability tools

In the next step `015` we will send egress traffic through a gateway pinned to dedicated egress nodes
