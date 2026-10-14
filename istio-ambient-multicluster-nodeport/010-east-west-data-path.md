# Trace the East-West Data Path and Measure Each Hop

# Objectives
- Trace four mesh paths through the ztunnel logs and name every proxy on each path
- Measure the latency of each path with fortio, from a no-mesh baseline to a cross-cluster call
- Send a central-gateway hostname straight to in-mesh pods with a `ServiceEntry`, with no application change
- List the cases where traffic still goes through a gateway or a proxy

## Prerequisites
- This lab assumes you have completed setup from labs `000-009`
- The waypoint from lab `009` is deployed in `bookinfo-backends`

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
```

## Background

In ambient mode, every enrolled pod's traffic is redirected to the ztunnel on its own node. For a call between two enrolled pods, the source ztunnel picks a destination pod and opens an HBONE connection (mTLS on port `15008`) directly to that pod's node, where the destination ztunnel delivers it. No gateway is involved. The source ztunnel resolves the Service and picks the endpoint itself, so kube-proxy or a CNI kube-proxy replacement does not load balance this traffic.

A call only gets an extra proxy when something adds one. This lab measures the same `/echo` handler over five paths:

| # | Path | Proxies between client and server |
|---|---|---|
| 1 | No mesh: `fortio-client-nomesh` to `echo-nomesh` | None. kube-proxy translates the Service IP |
| 2 | Ambient L4: `fortio-client` to `echo` | Source ztunnel, destination ztunnel |
| 3 | Ambient with a waypoint: `fortio-client` to `echo-l7` | Source ztunnel, waypoint (Envoy), destination ztunnel |
| 4 | Hairpin through the ingress gateway: `fortio-client` to agentgateway, which routes to `echo` | Source ztunnel, agentgateway, destination ztunnel |
| 5 | Cross-cluster: `fortio-client` to `echo-remote.perf.mesh.internal` | Source ztunnel, cluster2 east-west gateway (ztunnel), destination ztunnel in cluster2 |

Path 4 stands in for today's pattern, where internal callers reach other internal services through a central gateway. Path 2 is what ambient does when callers address the service directly.

The workloads are in `perf/perf-cluster1.yaml` and `perf/perf-cluster2.yaml`. Every client and server is a fortio pod, so every path serves the same handler and the numbers are comparable. The `-nomesh` pods carry the pod label `istio.io/dataplane-mode=none`, so they stay out of the mesh even though the `perf` namespace is enrolled.

## Deploy the Test Workloads

Deploy the clients, the targets, a waypoint for `echo-l7`, and an ingress route for `/echo` in cluster1. Deploy the cross-cluster target in cluster2:
```bash
kubectl apply -f perf/perf-cluster1.yaml --context $KUBECONTEXT_CLUSTER1
kubectl apply -f perf/perf-cluster2.yaml --context $KUBECONTEXT_CLUSTER2
kubectl wait --for=condition=Available deploy --all -n perf --timeout=180s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Available deploy --all -n perf --timeout=180s --context $KUBECONTEXT_CLUSTER2
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|perf"
```

Expected output (pod suffixes and addresses differ on your machine):
```
NAMESPACE           POD NAME                                                                 ADDRESS                                    NODE     WAYPOINT PROTOCOL
perf                autogen.cluster2.perf.echo-remote                                                                                            None     HBONE
perf                echo-959df6568-kbg7p                                                     10.244.0.40                                cluster1 None     HBONE
perf                echo-nomesh-75bbb89cb8-bfd9s                                             10.244.0.41                                cluster1 None     TCP
perf                fortio-client-76cc5c86c8-nf7hl                                           10.244.0.38                                cluster1 None     HBONE
perf                fortio-client-nomesh-54858c8c74-nhr9s                                    10.244.2.21                                worker-1 None     TCP
perf                waypoint-5dc9fb8d6-rnj78                                                 10.244.0.39                                cluster1 None     TCP
```

The two `-nomesh` pods are `TCP`, outside the mesh. The waypoint shows `TCP` because it terminates HBONE itself instead of going through ztunnel. `autogen.cluster2.perf.echo-remote` has no address: it is the cluster2 side of the global `echo-remote` Service, which ztunnel reaches through the cluster2 east-west gateway.

`echo-remote` is a global Service in cluster2 only, so cluster1 has a generated `ServiceEntry` for it and no local endpoints:
```bash
kubectl get serviceentry autogen.perf.echo-remote -n istio-system --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
NAME                       HOSTS                                LOCATION        RESOLUTION   AGE
autogen.perf.echo-remote   ["echo-remote.perf.mesh.internal"]   MESH_INTERNAL   STATIC       9s
```

> **The `perf` namespace is open to every mesh caller.** Lab `008` locked down the Bookinfo namespaces only. `perf` has no `ALLOW` policies, and its in-mesh callers use mTLS, so `STRICT` mode accepts them. The baseline client is outside the mesh and calls only the baseline target, which is outside the mesh too.

## Trace Each Path

Send one request over each path, then read what the cluster1 ztunnels logged for `fortio-client`:
```bash
for URL in http://echo:8080/echo http://echo-l7:8080/echo http://ingress.agentgateway-system/echo http://echo-remote.perf.mesh.internal:8080/echo; do
  kubectl exec deploy/fortio-client -n perf --context $KUBECONTEXT_CLUSTER1 -- fortio curl -quiet $URL > /dev/null 2>&1
done
sleep 2
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --since=1m --tail=-1 \
  | grep 'src.workload="fortio-client-' | grep 'direction="outbound"' | grep "connection complete" \
  | grep -oE 'dst.addr=[^ ]+|dst.service="[^"]+"|dst.workload="[^"]+"' | paste - - - | sort -u
```

Expected output (addresses differ on your machine):
```
dst.addr=10.244.0.27:80	dst.service="ingress.agentgateway-system.svc.cluster.local"	dst.workload="ingress-6496d9d9c8-knst9"
dst.addr=10.244.0.39:15008	dst.service="echo-l7.perf.svc.cluster.local"	dst.workload="waypoint-5dc9fb8d6-rnj78"
dst.addr=10.244.0.40:15008	dst.service="echo.perf.svc.cluster.local"	dst.workload="echo-959df6568-kbg7p"
dst.addr=172.30.0.4:31508	dst.service="echo-remote.perf.mesh.internal"	dst.workload="autogen.node.cluster2.cluster2.77f30e0c"
```

Each line is the first hop that the source ztunnel opened:

- `echo` goes straight to the `echo` pod IP on `15008`. This is path 2: one HBONE connection from node to node, and nothing in between.
- `echo-l7` goes to the waypoint pod on `15008`. The waypoint then opens a second HBONE connection to the `echo` pod.
- `ingress.agentgateway-system` goes to the agentgateway pod on port `80`, not `15008`. agentgateway runs outside ztunnel's capture (lab `005`), so this hop is plaintext. agentgateway then opens HBONE to `echo`. Hairpinning through a gateway adds a proxy hop, and also an unencrypted hop.
- `echo-remote` goes to `autogen.node.cluster2.<node>`, the entry istiod generated for the cluster2 node that runs the east-west pod (lab `007`). ztunnel connects to that node's IP on the HBONE NodePort `31508`.

The waypoint's own hop to `echo` appears only when its pooled connection closes, because ztunnel logs `connection complete` at close.

See the far side of the cross-cluster path in cluster2:
```bash
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER2 --since=1m --tail=-1 \
  | grep 'src.workload="fortio-client"' | grep "connection complete" | tail -1 \
  | grep -oE 'src.addr=[^ ]+|src.identity="[^"]+"|dst.workload="[^"]+"|dst.identity="[^"]+"' | paste - - - -
kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest --context $KUBECONTEXT_CLUSTER2 \
  -o custom-columns=POD:.metadata.name,POD_IP:.status.podIP,NODE:.spec.nodeName,NODE_IP:.status.hostIP
```

Expected output:
```
src.addr=10.244.0.10:47070	src.identity="spiffe://cluster1.local/ns/perf/sa/default"	dst.workload="echo-959df6568-qhvmj"	dst.identity="spiffe://cluster2.local/ns/perf/sa/default"
POD                               POD_IP        NODE     NODE_IP
istio-eastwest-58c688b6f8-fdjhz   10.244.0.10   cluster2 172.30.0.4
```

`src.addr` is the east-west gateway pod, and `src.identity` is still the original cluster1 client. The east-west gateway forwards the inner HBONE stream without terminating its mTLS, so the destination checks policy against the real caller, as lab `008` showed. `NODE_IP` is the `dst.addr` that cluster1 ztunnel used: HBONE goes to the node that runs the east-west pod. When that pod runs on a worker, this address differs from the remote-peer address (lab `007`).

## Measure Each Path

Define a helper that runs 15 seconds of load at 200 requests per second over 4 connections, and prints the latency percentiles in milliseconds:
```bash
measure() {
  kubectl exec deploy/$1 -n perf --context $KUBECONTEXT_CLUSTER1 -- \
    fortio load -qps 200 -t 15s -c 4 -quiet "$2" 2>&1 \
    | awk -v name="$3" '
        /^# target 50%/ { p50 = $4 * 1000 }
        /^# target 90%/ { p90 = $4 * 1000 }
        /^# target 99%/ { p99 = $4 * 1000 }
        /^Code 200/     { ok = $4 }
        END { printf "%-22s p50 %5.2f ms   p90 %5.2f ms   p99 %5.2f ms   200s %s\n", name, p50, p90, p99, ok }'
}
measure fortio-client-nomesh http://echo-nomesh:8080/echo                 "1 no mesh"
measure fortio-client        http://echo:8080/echo                        "2 ambient L4"
measure fortio-client        http://echo-l7:8080/echo                     "3 waypoint"
measure fortio-client        http://ingress.agentgateway-system/echo      "4 ingress hairpin"
measure fortio-client        http://echo-remote.perf.mesh.internal:8080/echo "5 cross-cluster"
```

Expected output (the run takes about 75 seconds; numbers differ on your machine):
```
1 no mesh              p50  0.53 ms   p90  0.91 ms   p99  1.00 ms   200s 3000
2 ambient L4           p50  0.65 ms   p90  0.95 ms   p99  2.27 ms   200s 3000
3 waypoint             p50  1.50 ms   p90  1.92 ms   p99  3.71 ms   200s 3000
4 ingress hairpin      p50  1.39 ms   p90  1.89 ms   p99  2.94 ms   200s 3000
5 cross-cluster        p50  1.06 ms   p90  1.85 ms   p99  3.75 ms   200s 3000
```

Ambient L4 adds a fraction of a millisecond over no mesh: it adds mTLS and identity, and keeps the same network path. The waypoint, the ingress hairpin and the east-west gateway each add a similar amount on top of the L4 path, because each one is a single proxy hop. Moving an internal call from path 4 to path 2 removes that hop, and the median drops by about half in the sample above. All 15,000 requests returned `200`.

> **These numbers come from a single-machine test cluster.** Every node runs on one host, so network latency between nodes is close to zero. Use the relative difference between paths to design your own test. On real hardware, run the same five paths at your production request rates, payload sizes and connection counts, and measure your current gateway path as the baseline.

## Bypass a Central Gateway Without Changing the Caller

Callers often reach internal services through a central gateway hostname, for example `api-gateway.corp.example`. Ambient does not remove a hop that the application asks for: if the caller connects to the gateway's address, the traffic goes to the gateway. To bypass it, make the hostname resolve to the service inside the mesh. ztunnel's DNS proxy (`ambient.dnsCapture: true`, set in lab `002`) answers for any host that a `ServiceEntry` declares.

Declare the gateway hostname as a mesh service whose endpoints are the `echo` pods:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: api-gateway-bypass
  namespace: perf
spec:
  hosts:
  - api-gateway.corp.example
  location: MESH_INTERNAL
  resolution: STATIC
  ports:
  - name: http
    number: 80
    targetPort: 8080
    protocol: HTTP
  workloadSelector:
    labels:
      app: echo
EOF
sleep 3
kubectl exec deploy/fortio-client -n perf --context $KUBECONTEXT_CLUSTER1 -- fortio curl -quiet http://api-gateway.corp.example/echo 2>&1 | head -1
sleep 2
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --since=1m --tail=-1 \
  | grep 'dst.service="api-gateway.corp.example"' | grep 'direction="outbound"' | tail -1 \
  | grep -oE 'dst.addr=[^ ]+|dst.workload="[^"]+"|dst.identity="[^"]+"' | paste - - -
```

Expected output:
```
HTTP/1.1 200 OK
dst.addr=10.244.0.40:15008	dst.workload="echo-959df6568-kbg7p"	dst.identity="spiffe://cluster1.local/ns/perf/sa/default"
```

The client still called `http://api-gateway.corp.example/echo`. ztunnel resolved the name to the `ServiceEntry`, and opened HBONE directly to the `echo` pod, which is path 2. Measure it:
```bash
measure fortio-client http://api-gateway.corp.example/echo "gateway hostname"
```

Expected output:
```
gateway hostname       p50  0.65 ms   p90  0.94 ms   p99  1.23 ms   200s 3000
```

The latency matches path 2.

> **The bypass also drops what the gateway did.** If the central gateway authenticates callers, rate-limits, or routes by path to different backends, the mesh must take over those jobs before you redirect the hostname. Use `AuthorizationPolicy` for caller identity (lab `008`), and a waypoint with `HTTPRoute` rules on the `ServiceEntry` for path routing (lab `009`). Redirect one hostname at a time, for one set of callers at a time. A `ServiceEntry` applies to the namespaces it is exported to, so you can scope the change with `exportTo`.

## Where the Bypass Does Not Apply

Ambient keeps east-west traffic direct between enrolled workloads. Traffic still goes through a proxy or a gateway in these cases:

| Case | What is in the path | Why |
|---|---|---|
| A service uses a waypoint | One Envoy hop | You asked for L7 features on that service (lab `009`) |
| The destination is in another network | The peer cluster's east-west gateway, reached on the node that runs it | Pod IPs are not routable between networks. Every cross-cluster call in this workshop crosses a network |
| The caller addresses a gateway (hostname or IP) | That gateway | The mesh does not rewrite a destination the caller chose. Redirect the hostname with a `ServiceEntry`, as above |
| The traffic enters or leaves the mesh | The ingress or egress gateway | North-south traffic is a gateway's job (labs `006` and `016`) |
| One side is outside the mesh | No ztunnel on that side, and no mTLS | `STRICT` (lab `008`) rejects plaintext into enrolled pods |
| A caller hairpins through a gateway in an excluded namespace | A plaintext hop to the gateway | The gateway pod is not enrolled. Send internal callers to the service instead |

Cross-namespace calls and calls across mTLS policy boundaries do not add a hop. Namespaces and `AuthorizationPolicy` change what is allowed, not the path.

> **Running on Cilium with kube-proxy replacement?** ztunnel does the Service load balancing for enrolled pods, so it must see the original Service IP. Istio's [platform prerequisites](https://istio.io/latest/docs/ambient/install/platform-prerequisites/#cilium) list the Cilium settings ambient needs, including `socketLB.hostNamespaceOnly=true`.

## Cleanup

Remove the bypass `ServiceEntry` and the test workloads from both clusters:
```bash
kubectl delete serviceentry api-gateway-bypass -n perf --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete -f perf/perf-cluster1.yaml --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete -f perf/perf-cluster2.yaml --context $KUBECONTEXT_CLUSTER2 --ignore-not-found
```

## Next Steps
At this point we have completed the following objectives:
- Traced four mesh paths through the ztunnel logs and named every proxy on each path
- Measured the latency of each path with fortio, from a no-mesh baseline to a cross-cluster call
- Sent a central-gateway hostname straight to in-mesh pods with a `ServiceEntry`, with no application change
- Listed the cases where traffic still goes through a gateway or a proxy

In the next step `011` we will collect mesh metrics from both clusters into one Prometheus and Grafana
