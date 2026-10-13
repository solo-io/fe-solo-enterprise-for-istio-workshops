# Move a Stable Hostname Between Clusters

# Objectives
- Serve a customer-facing hostname, `bookinfo.example.com`, that does not encode a cluster name
- Give each cluster's copy of productpage its own global hostname
- Shift the hostname from cluster1 to cluster2 by route weight, under load, with no failed requests
- See why a cluster-specific backend has no failover, and finish the move on the global hostname

## Prerequisites
- This lab assumes you have completed setup from labs `000-011`
- (Optional) Vegeta for load generation: see [000-tools.md](000-tools.md#vegeta-cli-load-generator)

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
[ -n "$INGRESS_ADDR" ] || echo "⚠️  INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

## Background

When a hostname such as `app.cluster1.example.com` names a cluster, moving the workload means a DNS change, a certificate change and a firewall change, and every client has to follow. A mesh lets you separate the two: the client keeps one hostname, and the route behind it decides which cluster serves each request.

This lab uses three kinds of hostnames:

| Hostname | Who uses it | Resolves to |
|---|---|---|
| `bookinfo.example.com` | Customers. Never changes | The ingress gateway. The `HTTPRoute` on it picks the backend |
| `productpage-cluster1.bookinfo-frontends.mesh.internal` and `productpage-cluster2...` | The platform team's route only | productpage pods in one cluster |
| `productpage.bookinfo-frontends.mesh.internal` | Everyone else, and the route once the move is done | productpage pods in every cluster, local first (lab `007`) |

The cluster-specific hostnames come from one `Service` per cluster with the `solo.io/service-scope=global` label. Each one exists in a single cluster, so its global hostname has endpoints in that cluster only. The weights in the `HTTPRoute` then decide how much traffic each cluster gets. The customer's hostname, DNS record and certificate stay the same throughout.

> **Ingress in more than one cluster.** In this workshop only cluster1 runs an ingress gateway. In production, run the same `Gateway` and `HTTPRoute` in each cluster, and put the customer hostname on a DNS name or global load balancer that targets every cluster's ingress. The weights below then work from whichever ingress a request arrives at, because every route points at the same mesh hostnames.

## Create a Hostname per Cluster

Create a `productpage-cluster1` Service in cluster1 and a `productpage-cluster2` Service in cluster2. Both select the same productpage pods as the `productpage` Service, so the lab `008` policies apply to them unchanged:
```bash
for N in 1 2; do
  CONTEXT=$(eval echo \$KUBECONTEXT_CLUSTER$N)
  kubectl apply --context $CONTEXT -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: productpage-cluster$N
  namespace: bookinfo-frontends
  labels:
    solo.io/service-scope: global
spec:
  selector:
    app: productpage
  ports:
  - name: http
    port: 9080
EOF
done
sleep 3
kubectl get serviceentry -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAME|productpage"
```

Expected output:
```
NAME                                              HOSTS                                                       LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage            ["productpage.bookinfo-frontends.mesh.internal"]            MESH_INTERNAL   STATIC       6h31m
autogen.bookinfo-frontends.productpage-cluster1   ["productpage-cluster1.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       3s
autogen.bookinfo-frontends.productpage-cluster2   ["productpage-cluster2.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       3s
```

## Serve the Customer Hostname from cluster1

Add an `HTTPRoute` for `bookinfo.example.com` that sends all traffic to cluster1. The existing `bookinfo-route` from lab `007` keeps serving requests for any other hostname:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-canary
  namespace: bookinfo-frontends
spec:
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  hostnames:
  - bookinfo.example.com
  rules:
  - backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: productpage-cluster1.bookinfo-frontends.mesh.internal
      port: 9080
      weight: 100
    - kind: Hostname
      group: networking.istio.io
      name: productpage-cluster2.bookinfo-frontends.mesh.internal
      port: 9080
      weight: 0
EOF
sleep 3
```

There is no DNS record for `bookinfo.example.com` in this workshop, so the requests set the `Host` header instead. Define two helpers: one counts which cluster served 20 requests, the other changes the two weights:
```bash
count_clusters() {
  for i in $(seq 1 20); do
    curl -s -H "Host: bookinfo.example.com" http://$INGRESS_ADDR/productpage | grep -oE "cluster[12]" | head -1
  done | sort | uniq -c
}
set_weights() {
  kubectl patch httproute bookinfo-canary -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}]"
}
count_clusters
```

Expected output:
```
  20 cluster1
```

## Canary 10 Percent to cluster2

```bash
set_weights 90 10
sleep 3
count_clusters
```

Expected output (the split varies from run to run):
```
  17 cluster1
   3 cluster2
```

The ingress gateway in cluster1 now sends about one request in ten across the east-west gateway to cluster2. productpage in cluster2 calls the reviews service in its own cluster, which is why the page reports `cluster2`.

## Move the Hostname Under Load

The canary is healthy. Complete the move in steps while a steady load runs, and check that no request fails during the changes. Vegeta sends 20 requests per second for 80 seconds and the weights change every 20 seconds:
```bash
printf 'GET http://%s/productpage\nHost: bookinfo.example.com\n' "$INGRESS_ADDR" > canary-targets.txt
vegeta attack -targets=canary-targets.txt -duration=80s -rate=20 | vegeta report --type=text > canary-report.txt &
LOAD_PID=$!
sleep 20; set_weights 50 50
sleep 20; set_weights 10 90
sleep 20; set_weights 0 100
wait $LOAD_PID
cat canary-report.txt
count_clusters
```

Expected output (latencies differ on your machine):
```
httproute.gateway.networking.k8s.io/bookinfo-canary patched
httproute.gateway.networking.k8s.io/bookinfo-canary patched
httproute.gateway.networking.k8s.io/bookinfo-canary patched
Requests      [total, rate, throughput]         1600, 20.01, 20.01
Duration      [total, attack, wait]             1m20s, 1m20s, 9.394ms
Latencies     [min, mean, 50, 90, 95, 99, max]  8.455ms, 12.425ms, 12.196ms, 14.155ms, 15.04ms, 31.141ms, 65.405ms
Bytes In      [total, mean]                     21372462, 13357.79
Bytes Out     [total, mean]                     0, 0.00
Success       [ratio]                           100.00%
Status Codes  [code:count]                      200:1600  
Error Set:
  20 cluster2
```

All 1600 requests succeeded while the hostname moved from cluster1 to cluster2. The client kept the same hostname, and DNS, certificates and client configuration stayed the same. Rolling back is the same patch in reverse.

> **No Vegeta?** Run `count_clusters` after each `set_weights` call instead. You see the split move, but not the success ratio under load.

## A Cluster-Specific Backend Has No Failover

The route now sends everything to `productpage-cluster2`, a hostname with endpoints in cluster2 only. See what happens when cluster2 loses productpage:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $KUBECONTEXT_CLUSTER2
kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER2
sleep 2
curl -s -H "Host: bookinfo.example.com" -w " (%{http_code})\n" http://$INGRESS_ADDR/productpage
```

Expected output:
```
no healthy upstream (503)
```

cluster1 still runs a healthy productpage, but the route does not use it. A weight of `0` removes a backend completely, and Gateway API does not fail over between `backendRefs`. The cluster-specific hostnames are for the move only.

Finish the move on the global hostname, which has every cluster's endpoints and the `PreferNetwork` failover from lab `007`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-canary
  namespace: bookinfo-frontends
spec:
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  hostnames:
  - bookinfo.example.com
  rules:
  - backendRefs:
    - kind: Hostname
      group: networking.istio.io
      name: productpage.bookinfo-frontends.mesh.internal
      port: 9080
EOF
sleep 3
count_clusters
```

Expected output:
```
  20 cluster1
```

The request succeeds again, served by cluster1, because the global hostname fails over to the remaining cluster. Bring cluster2 back:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 1 --context $KUBECONTEXT_CLUSTER2
kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER2
```

For a real migration off cluster1, the last steps are: route the hostname to the global hostname, as above, then scale the workload down in cluster1. The global hostname then has cluster2 endpoints only, and if you redeploy in cluster1 later, it fails over between clusters again.

## Cleanup

Remove the canary route, the per-cluster Services and the local load files:
```bash
kubectl delete httproute bookinfo-canary -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete svc productpage-cluster1 -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete svc productpage-cluster2 -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER2 --ignore-not-found
rm -f canary-targets.txt canary-report.txt
```

## Next Steps
At this point we have completed the following objectives:
- Served a customer-facing hostname, `bookinfo.example.com`, that does not encode a cluster name
- Gave each cluster's copy of productpage its own global hostname
- Shifted the hostname from cluster1 to cluster2 by route weight, under load, with no failed requests
- Saw why a cluster-specific backend has no failover, and finished the move on the global hostname

In the next step `013` we will keep NodePort peering healthy as nodes, NodePorts and clusters change
