# Carry the Real Client IP Through the Ingress Gateway

# Objectives
- See which client address the ingress gateway records with `externalTrafficPolicy: Cluster` and with `Local`
- Accept PROXY protocol from a load balancer, so the gateway records the client behind it
- Follow the client IP from the gateway to a backend in the same cluster and in the peer cluster
- Record the client IP in the gateway log for observability tools

## Prerequisites
- This lab assumes you have completed setup from labs `000-014`

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
```

## Background

A request from outside the cluster passes through up to three components that can replace its source address before the ingress gateway sees it:

| Component | What it does to the source address | How to keep the client address |
|---|---|---|
| External load balancer (hardware, or cloud) | A proxying load balancer opens a new connection, so the source becomes the load balancer | PROXY protocol: the load balancer sends the client address in a header at the start of the connection |
| kube-proxy, for a `NodePort` or `LoadBalancer` Service | `externalTrafficPolicy: Cluster` can forward to a pod on any node, and SNATs the connection | `externalTrafficPolicy: Local`: only nodes with a gateway pod accept traffic, and kube-proxy keeps the source |
| The ingress gateway | Terminates the client connection and opens a new one to the backend | A gateway policy writes the source address the gateway saw into `X-Forwarded-For` |

After the gateway, the backend's L4 source is always the gateway, or the peer cluster's east-west gateway for a cross-cluster call. The client IP reaches the backend as an HTTP header, and it reaches observability tools through the gateway's log.

agentgateway adds no `X-Forwarded-For` header on its own, and it forwards a header that the client sent unchanged. This lab's gateway policy sets the header from the connection's source address, with the CEL expression `source.address`. Setting the header replaces whatever the client sent, so a client cannot forge its own address.

This lab uses a separate agentgateway `ingress-edge` Gateway with a `NodePort` Service, so the changes do not affect the `ingress` Gateway that the other labs use. A namespace `outside` in cluster2, outside the mesh, plays the external side:

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

Create the `ingress-edge` Gateway in cluster1 with its own parameters, route it to the global `echo` hostname, and attach the policy that sets `X-Forwarded-For`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ingress-edge-config
  namespace: agentgateway-system
spec:
  istio:
    enabled: true
    trustDomain: $MESH_NAME_CLUSTER1.local
    clusterId: $MESH_NAME_CLUSTER1
    network: $MESH_NAME_CLUSTER1
  service:
    spec:
      type: NodePort
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress-edge
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: ingress-edge-config
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
    namespace: agentgateway-system
  rules:
  - backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: echo.client-ip.mesh.internal
      port: 8080
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ingress-edge-client-ip
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ingress-edge
  traffic:
    transformation:
      request:
        set:
        - name: x-forwarded-for
          value: source.address
EOF
kubectl wait --for=condition=Programmed gateway/ingress-edge -n agentgateway-system --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/ingress-edge -n agentgateway-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
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
export EDGE_PORT=$(kubectl get svc ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
export GATEWAY_NODE_IP=$(kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=ingress-edge \
  --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].status.hostIP}')
export OTHER_NODE_IP=$(kubectl get nodes --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | grep -v "^$GATEWAY_NODE_IP$" | head -1)
kubectl get pod -n outside -l app=client --context $KUBECONTEXT_CLUSTER2 \
  -o jsonpath='client pod IP {.items[0].status.podIP}, client node IP {.items[0].status.hostIP}{"\n"}'
echo "edge NodePort $EDGE_PORT, gateway node $GATEWAY_NODE_IP, other node $OTHER_NODE_IP"
```

Expected output (addresses differ on your machine):
```
client pod IP 10.244.1.44, client node IP 172.30.0.5
edge NodePort 31701, gateway node 172.30.0.3, other node 172.30.0.2
```

Define a helper that sends a request from the client and prints the fields that matter. `IP` is the source address the `echo` pod saw. Extra arguments go to `curl`:
```bash
call_edge() {
  kubectl exec deploy/client -n outside --context $KUBECONTEXT_CLUSTER2 -- curl -s -m 5 "$@" 2>/dev/null \
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
IP=10.244.1.74
RequestHeader=X-Forwarded-For:10.244.1.1
== via the other node
Cluster=cluster1
IP=10.244.1.74
RequestHeader=X-Forwarded-For:10.244.0.0
```

`X-Forwarded-For` should hold the client address, `172.30.0.5`, but holds a cluster1-internal address instead: kube-proxy SNATs NodePort traffic under `Cluster`. `IP=10.244.1.74` is the edge gateway pod, which is the backend's L4 source in every case.

## With externalTrafficPolicy Local

agentgateway builds the gateway's Service from the `service` field of the Gateway's parameters. Set `externalTrafficPolicy: Local` there:
```bash
kubectl patch enterpriseagentgatewayparameters ingress-edge-config -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 \
  --type=merge -p '{"spec":{"service":{"spec":{"externalTrafficPolicy":"Local"}}}}'
for i in $(seq 1 20); do
  [ "$(kubectl get svc ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.externalTrafficPolicy}')" = Local ] && break
  sleep 1
done
kubectl get svc ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
echo "== via the gateway's node"; call_edge http://$GATEWAY_NODE_IP:$EDGE_PORT/
echo "== via the other node";     call_edge http://$OTHER_NODE_IP:$EDGE_PORT/
```

Expected output:
```
Local
== via the gateway's node
Cluster=cluster1
IP=10.244.1.74
RequestHeader=X-Forwarded-For:172.30.0.5
== via the other node
no response
```

The gateway now records the client address, `172.30.0.5`. The other node has no gateway pod, so under `Local` it drops the connection. Whatever sends traffic to the NodePorts must use only nodes with a gateway pod: a cloud load balancer does this through the Service's `healthCheckNodePort`, and a hardware load balancer needs a health check on the same port.

## Accept PROXY Protocol from a Load Balancer

A proxying load balancer, such as a hardware load balancer in proxy mode or a cloud load balancer that terminates connections, replaces the client address with its own. PROXY protocol carries the original address in a header at the start of each connection. Turn it on for the edge gateway in the `frontend` section of its policy. With PROXY protocol on, `source.address` is the address from the PROXY header:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: ingress-edge-client-ip
  namespace: agentgateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ingress-edge
  frontend:
    proxyProtocol:
      mode: Strict
      version: V2
  traffic:
    transformation:
      request:
        set:
        - name: x-forwarded-for
          value: source.address
EOF
sleep 3
```

`mode: Strict` requires the header on every connection. `Optional` also accepts connections without it, which lets a client that reaches the gateway directly set its own source address, so use `Strict` on a gateway that sits behind a load balancer.

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
IP=10.244.1.74
RequestHeader=X-Forwarded-For:10.244.1.44
== direct (no PROXY header)
no response
```

`X-Forwarded-For` is now `10.244.1.44`, the client pod IP. haproxy saw the client before any SNAT and passed that address in the PROXY header. The direct request fails under `Strict`. Put every client of a PROXY protocol gateway behind the load balancer, and keep a separate gateway for clients that connect directly.

The gateway log records the direct attempt, with the address that connected:
```bash
kubectl logs deploy/ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --since=2m | grep -m1 "PROXY protocol header missing"
```

Expected output:
```
2026-10-14T02:53:48.561966Z	warn	proxy::gateway	proxy protocol error: PROXY protocol header missing	connection.id=6 src.addr=172.30.0.4:33627
```

Send a forged `X-Forwarded-For` through haproxy:
```bash
call_edge http://haproxy:8080/ -H "X-Forwarded-For: 203.0.113.9"
```

Expected output:
```
Cluster=cluster1
IP=10.244.1.74
RequestHeader=X-Forwarded-For:10.244.1.44
```

The backend sees the client address from the PROXY header, not `203.0.113.9`.

## Follow the Client IP Across Clusters

agentgateway writes one `request` line per request to its log, with the source address it read in `src.addr`. Scale `echo` to zero in cluster1, so the gateway fails over to cluster2, call it through haproxy, and read the key fields of the gateway's last request line:
```bash
kubectl scale deploy/echo -n client-ip --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=echo -n client-ip --timeout=60s --context $KUBECONTEXT_CLUSTER1
sleep 3
call_edge http://haproxy:8080/
sleep 2
kubectl logs deploy/ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --since=1m | grep "request gateway=" | tail -1 \
  | grep -oE "(route|endpoint|src\.addr|http\.status)=[^ ]+"
```

Expected output:
```
Cluster=cluster2
IP=10.244.1.30
RequestHeader=X-Forwarded-For:10.244.1.44
route=client-ip/echo
endpoint=echo.client-ip.mesh.internal:8080
src.addr=10.244.1.44:35074
http.status=200
```

cluster2 served the request. Its L4 source, `IP=10.244.1.30`, is the cluster2 east-west gateway, and `X-Forwarded-For` still carries the client, `10.244.1.44`. In the gateway log, `src.addr` is the client address that the gateway read from the PROXY header, and `route` and `endpoint` show which route and global hostname served it. Ship these logs to your log pipeline to report client addresses per request.

Bring `echo` back in cluster1:
```bash
kubectl scale deploy/echo -n client-ip --replicas 1 --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/echo -n client-ip --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

## On-Premises and Cloud

| Environment | Load balancer in front of the gateway | Settings that keep the client address |
|---|---|---|
| On-premises, hardware load balancer in proxy mode | Opens a new connection per client | PROXY protocol on the load balancer and `frontend.proxyProtocol` on the gateway policy, as above. `externalTrafficPolicy: Local` if the load balancer targets NodePorts |
| On-premises, L3/L4 load balancer that keeps the source (for example BGP or ECMP to the nodes) | Forwards packets with the client source | `externalTrafficPolicy: Local` only |
| AWS Network Load Balancer | Keeps the source for instance targets, or sends PROXY protocol v2 when you turn it on for the target group | `externalTrafficPolicy: Local`, or PROXY protocol on both sides |
| Azure Standard Load Balancer | Forwards packets with the client source | `externalTrafficPolicy: Local` |
| Any L7 load balancer that terminates HTTP | Adds `X-Forwarded-For` | Remove the `x-forwarded-for` transformation from the gateway policy, so the gateway forwards the load balancer's header unchanged, and accept traffic from the load balancer only |

The steps after the gateway are the same everywhere: the client IP travels in `X-Forwarded-For` to the backend, in the same cluster or across clusters, and the gateway log records it. Confirm the load balancer behavior for your own load balancer models and settings with the same `call_edge` test.

## Cleanup

Remove the edge gateway, its parameters and policy, the `echo` backend and the `outside` namespace:
```bash
kubectl delete httproute echo -n client-ip --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete enterpriseagentgatewaypolicy ingress-edge-client-ip -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete gateway ingress-edge -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete enterpriseagentgatewayparameters ingress-edge-config -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace client-ip --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace client-ip outside --context $KUBECONTEXT_CLUSTER2 --ignore-not-found
```

## Next Steps
At this point we have completed the following objectives:
- Saw which client address the ingress gateway recorded with `externalTrafficPolicy: Cluster` and with `Local`
- Accepted PROXY protocol from a load balancer, so the gateway recorded the client behind it
- Followed the client IP from the gateway to a backend in the same cluster and in the peer cluster
- Recorded the client IP in the gateway log for observability tools

In the next step `016` we will send egress traffic through a gateway pinned to dedicated egress nodes
