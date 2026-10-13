# Enforce Zero Trust and Quarantine a Workload Across Clusters

# Objectives
- Apply a deny-all baseline in both clusters, then allow each Bookinfo hop by SPIFFE identity
- List each cluster's trust domain explicitly in policy, and show what breaks when a cluster trusts only itself
- Require mTLS mesh-wide with a `STRICT` PeerAuthentication
- Quarantine a single suspect pod by removing it from the mesh
- Quarantine a whole identity in every cluster with a root-namespace `DENY` policy

## Prerequisites
- This lab assumes you have completed setup from labs `000-006`
- `productpage` is a global service and the ingress route points at `productpage.bookinfo-frontends.mesh.internal` (lab `006`)

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
[ -n "$INGRESS_ADDR" ] || echo "⚠️  INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 005 in this shell, or its port-forward fallback."
```

## Background

ztunnel enforces L4 authorization on the destination side. When a connection arrives, the ztunnel on the destination node reads the caller's SPIFFE identity from the mTLS certificate and checks it against the `AuthorizationPolicy` resources in the destination cluster. No other proxy is involved, and nothing in the source cluster can override that decision.

Three properties of this design matter in a multicluster mesh:

| Property | Effect in this workshop |
|---|---|
| Each cluster has its own trust domain (`cluster1.local`, `cluster2.local`) | A caller in cluster1 shows up in cluster2 as `spiffe://cluster1.local/ns/...`. A policy in cluster2 must name that trust domain to allow it |
| Policy is evaluated where the destination runs | A failover from cluster1 to cluster2 is checked against cluster2's policies. Every cluster needs the same policy set |
| `DENY` is evaluated before `ALLOW` | One `DENY` policy in the root namespace `istio-system` blocks an identity for every workload in that cluster, whatever the `ALLOW` policies say |

> **Why list trust domains instead of `*/ns/...`?** A `*` trust domain matches every identity signed by the shared root CA. That is convenient, and it also trusts any future cluster you peer with. Listing `cluster1.local` and `cluster2.local` keeps the trust set explicit: a new cluster gets access only when you add its trust domain to the policies.

The policies for this lab are in `auth-policy/`. Each file allows one Bookinfo hop from both trust domains.

## Apply a Deny-All Baseline

Confirm the application works before you change anything:
```bash
curl -s http://$INGRESS_ADDR/productpage -o /dev/null -w "%{http_code}\n"
```

You should see `200`.

An `ALLOW` policy with an empty spec matches nothing, so once it exists in a namespace, every connection into that namespace is denied until another policy allows it. Apply it to both Bookinfo namespaces in both clusters:
```bash
cat auth-policy/allow-nothing.yaml
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply -f auth-policy/allow-nothing.yaml --context $context
done
sleep 3
curl -s http://$INGRESS_ADDR/productpage
```

Expected output:
```
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

The ingress gateway reached the ztunnel in front of productpage, and ztunnel closed the connection. Find the rejection in the cluster1 ztunnel logs:
```bash
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --prefix --since=1m --tail=-1 | grep "policy rejection" | tail -1
```

Expected output:
```
[pod/ztunnel-cqfgc/istio-proxy] 2026-10-12T23:07:49.901833Z	error	access	connection complete	src.addr=10.244.2.68:60880 src.workload="ingress-istio-647c569-p8pj8" src.namespace="istio-system" src.identity="spiffe://cluster1.local/ns/istio-system/sa/ingress-istio" dst.addr=10.244.2.74:15008 dst.hbone_addr=10.244.2.74:9080 dst.service="productpage.bookinfo-frontends.mesh.internal" dst.workload="productpage-v1-59c74584cf-cqsrr" dst.namespace="bookinfo-frontends" dst.identity="spiffe://cluster1.local/ns/bookinfo-frontends/sa/bookinfo-productpage" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

`src.identity` is the caller and `dst.identity` is the workload being protected. `error=... allow policies exist, but none allowed` names the reason: `allow-nothing` exists, and no policy allows the ingress gateway.

## Allow Each Hop by Identity

Look at one of the allow policies. The `principals` list names the caller in both trust domains:
```bash
cat auth-policy/productpage-auth.yaml
```

Apply the four allow policies in both clusters. They allow ingress to productpage, productpage to details and reviews, and reviews to ratings:
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply --context $context \
    -f auth-policy/productpage-auth.yaml \
    -f auth-policy/details-auth.yaml \
    -f auth-policy/reviews-auth.yaml \
    -f auth-policy/ratings-auth.yaml
done
sleep 3
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]|Error fetching[^<]*" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster1
```

No `Error fetching` lines appear, so every hop is allowed. Every other connection into the Bookinfo namespaces is still denied.

## Check the Policies Across Clusters

Scale productpage to zero in cluster1 so the ingress gateway fails over to cluster2:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
curl -s http://$INGRESS_ADDR/productpage | grep -oE "<title>.*</title>|cluster[12]|Error fetching[^<]*" | sort | uniq -c
```

Expected output:
```
   1 <title>Simple Bookstore App</title>
   2 cluster2
```

The cluster1 ingress gateway called productpage in cluster2, and cluster2 allowed it because `productpage-auth` lists `cluster1.local/ns/istio-system/sa/ingress-istio`.

Now see what happens when a cluster trusts only its own trust domain. Remove the `cluster1.local` entry from the cluster2 policy:
```bash
kubectl patch authorizationpolicy productpage-auth -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER2 --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/from/0/source/principals","value":["cluster2.local/ns/istio-system/sa/ingress-istio"]}]'
sleep 3
curl -s http://$INGRESS_ADDR/productpage -o /dev/null -w "%{http_code}\n"
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER2 --prefix --since=1m --tail=-1 | grep "policy rejection" | tail -1
```

Expected output:
```
503
[pod/ztunnel-k82tv/istio-proxy] 2026-10-12T23:08:13.415577Z	error	access	connection complete	src.addr=10.244.2.56:37352 src.workload="ingress-istio" src.namespace="istio-system" src.identity="spiffe://cluster1.local/ns/istio-system/sa/ingress-istio" dst.addr=10.244.2.42:15008 dst.hbone_addr=productpage.bookinfo-frontends.mesh.internal:9080 dst.service="productpage.bookinfo-frontends.mesh.internal" dst.workload="productpage-v1-59c74584cf-pxvqb" dst.namespace="bookinfo-frontends" dst.identity="spiffe://cluster2.local/ns/bookinfo-frontends/sa/bookinfo-productpage" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

The cluster2 ztunnel rejected `spiffe://cluster1.local/...`. Two more fields show the cross-cluster path. `src.addr` is the cluster2 east-west gateway pod, which delivered the HBONE connection from the NodePort. `src.workload="ingress-istio"` has no pod suffix, because cluster2 knows the caller only through peering. This is the symptom to look for when failover works in one direction and fails in the other: the destination cluster's policy is missing the caller's trust domain.

Restore the policy and scale productpage back up in cluster1:
```bash
kubectl apply -f auth-policy/productpage-auth.yaml --context $KUBECONTEXT_CLUSTER2
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 1 --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

## Require mTLS Mesh-Wide

The `allow-nothing` baseline protects the Bookinfo namespaces, because a plaintext connection has no identity and matches no `principals` rule. A namespace with no policies still accepts plaintext from workloads outside the mesh. A `STRICT` PeerAuthentication in the root namespace closes that gap for every enrolled workload in the cluster:
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply --context $context -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
done
sleep 3
curl -s http://$INGRESS_ADDR/productpage -o /dev/null -w "%{http_code}\n"
```

You should see `200`. Every Bookinfo caller is already in the mesh, so nothing breaks. In ambient, `STRICT` is the only PeerAuthentication mode that changes behavior. ztunnel always sends mTLS between enrolled workloads, so `PERMISSIVE` and per-port settings have nothing to tune.

## Quarantine a Suspect Pod

Quarantine is the incident response case: one workload is suspect, and you need to cut its mesh access without waiting for an application change. Deploy a client in a new `tenant-a` namespace in cluster1 that stands in for a team's workload with legitimate access to productpage. It runs two replicas, so you can quarantine one and leave the other working:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: curl-client
  namespace: tenant-a
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-client
  namespace: tenant-a
spec:
  replicas: 2
  selector:
    matchLabels:
      app: curl-client
  template:
    metadata:
      labels:
        app: curl-client
    spec:
      serviceAccountName: curl-client
      containers:
      - name: curl
        image: curlimages/curl:8.22.0
        command: ["sleep", "infinity"]
EOF
kubectl rollout status deploy/curl-client -n tenant-a --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
```

Grant `tenant-a` access to productpage in both clusters. `ALLOW` policies add up, so a second policy grants the access without editing `productpage-auth`:
```bash
cat auth-policy/productpage-tenant-a-auth.yaml
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl apply -f auth-policy/productpage-tenant-a-auth.yaml --context $context
done
sleep 3
```

Define a helper that calls productpage from every `curl-client` pod, once through the global hostname and once through the cluster-local Service name:
```bash
call_from_tenant_a() {
  for POD in $(kubectl get pods -n tenant-a -l app=curl-client --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[*].metadata.name}'); do
    for HOST in productpage.bookinfo-frontends.mesh.internal productpage.bookinfo-frontends; do
      kubectl exec $POD -n tenant-a --context $KUBECONTEXT_CLUSTER1 -- \
        curl -s -m 5 -o /dev/null -w "$POD $HOST %{http_code}\n" http://$HOST:9080/productpage
    done
  done
}
call_from_tenant_a
```

Expected output (pod names differ on your machine):
```
curl-client-76544d6c64-mp87v productpage.bookinfo-frontends.mesh.internal 200
curl-client-76544d6c64-mp87v productpage.bookinfo-frontends 200
curl-client-76544d6c64-p2lvg productpage.bookinfo-frontends.mesh.internal 200
curl-client-76544d6c64-p2lvg productpage.bookinfo-frontends 200
```

Pick the first pod as the suspect and take it out of the mesh. The pod label `istio.io/dataplane-mode=none` overrides the namespace label for that pod only. istio-cni removes the pod's traffic redirection, and ztunnel stops serving a certificate for it:
```bash
export SUSPECT=$(kubectl get pods -n tenant-a -l app=curl-client --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].metadata.name}')
kubectl label pod $SUSPECT -n tenant-a istio.io/dataplane-mode=none --context $KUBECONTEXT_CLUSTER1
sleep 3
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|tenant-a"
```

Expected output:
```
NAMESPACE          POD NAME                                        ADDRESS     NODE     WAYPOINT PROTOCOL
tenant-a           curl-client-76544d6c64-mp87v                    10.244.2.77 worker-1 None     TCP
tenant-a           curl-client-76544d6c64-p2lvg                    10.244.2.76 worker-1 None     HBONE
```

The suspect is now `TCP`, which means plaintext with no mesh identity. Its sibling is still `HBONE`. Call productpage again:
```bash
call_from_tenant_a 2>&1 | grep -v "command terminated"
```

Expected output:
```
curl-client-76544d6c64-mp87v productpage.bookinfo-frontends.mesh.internal 000
curl-client-76544d6c64-mp87v productpage.bookinfo-frontends 000
curl-client-76544d6c64-p2lvg productpage.bookinfo-frontends.mesh.internal 200
curl-client-76544d6c64-p2lvg productpage.bookinfo-frontends 200
```

The suspect failed in two different ways:

- The global hostname does not resolve (curl exit code `6`). ztunnel's DNS proxy answers `*.mesh.internal`, and a pod outside the mesh no longer reaches it. The suspect cannot even find services in the other cluster.
- The cluster-local Service resets the connection (curl exit code `56`). The connection arrives as plaintext, and the destination ztunnel rejects it.

Find the rejection in the ztunnel logs:
```bash
SUSPECT_IP=$(kubectl get pod $SUSPECT -n tenant-a --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.status.podIP}')
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --prefix --since=1m --tail=-1 | grep "src.addr=$SUSPECT_IP" | tail -1
```

Expected output:
```
[pod/ztunnel-cqfgc/istio-proxy] 2026-10-12T23:09:04.582119Z	error	access	connection complete	src.addr=10.244.2.77:57540 src.workload="curl-client-76544d6c64-mp87v" src.namespace="tenant-a" dst.addr=10.244.2.75:9080 dst.service="productpage.bookinfo-frontends.svc.cluster.local" dst.workload="productpage-v1-59c74584cf-qlppm" dst.namespace="bookinfo-frontends" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

The line has no `src.identity` field, and `dst.addr` uses the application port `9080`, not the HBONE port `15008`. The connection arrived as plaintext with no identity to match.

Pod-level quarantine leaves the pod running, so you can still collect its logs and inspect it. Anyone with permission to patch pods in the namespace can remove the label, so restrict that RBAC in production. Release the pod:
```bash
kubectl label pod $SUSPECT -n tenant-a istio.io/dataplane-mode- --context $KUBECONTEXT_CLUSTER1
sleep 3
call_from_tenant_a
```

All four lines return `200` again.

## Quarantine an Identity in Every Cluster

Pod-level quarantine handles one pod. When a credential or an image is compromised, every pod with that service account is suspect, including pods that the next rollout creates. A `DENY` policy in the root namespace blocks the identity for every workload in the cluster, and `DENY` wins over any `ALLOW`.

Apply it in cluster1 first:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: quarantine
  namespace: istio-system
spec:
  action: DENY
  rules:
  - from:
    - source:
        principals:
        - cluster1.local/ns/tenant-a/sa/curl-client
EOF
sleep 3
```

Call productpage four times through each hostname, and print the cluster that served each call:
```bash
served_by() {
  for i in 1 2 3 4; do
    BODY=$(kubectl exec deploy/curl-client -n tenant-a --context $KUBECONTEXT_CLUSTER1 -- \
      curl -s -m 5 http://$1:9080/productpage 2>/dev/null)
    echo "$1 call $i: $(printf '%s' "$BODY" | grep -oE 'cluster[12]' | head -1 | grep . || echo denied)"
  done
}
served_by productpage.bookinfo-frontends
served_by productpage.bookinfo-frontends.mesh.internal
```

Expected output:
```
productpage.bookinfo-frontends call 1: denied
productpage.bookinfo-frontends call 2: denied
productpage.bookinfo-frontends call 3: denied
productpage.bookinfo-frontends call 4: denied
productpage.bookinfo-frontends.mesh.internal call 1: cluster2
productpage.bookinfo-frontends.mesh.internal call 2: cluster2
productpage.bookinfo-frontends.mesh.internal call 3: cluster2
productpage.bookinfo-frontends.mesh.internal call 4: cluster2
```

The cluster-local hostname is blocked on every call. The global hostname works on every call, and cluster2 serves it. Find the reason in the cluster1 ztunnel logs:
```bash
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --since=1m --tail=-1 \
  | grep 'src.workload="curl-client' | grep 'direction="outbound"' | grep -E 'error=|response_code=' \
  | sed -E 's/.*(dst.workload="[^"]+").*(error="[^"]+"|response_code=[0-9]+).*/\1 \2/' | sort | uniq -c
```

Expected output:
```
   4 dst.workload="NetworkGateway/cluster2/172.30.0.4/31213" response_code=200
   4 dst.workload="productpage-v1-59c74584cf-9glph" error="http status: 401 Unauthorized"
```

The four calls to the cluster-local hostname reached the cluster1 productpage pod, and its ztunnel rejected each one (`401 Unauthorized` on the HBONE `CONNECT`). The source ztunnel treated those rejections as an unhealthy endpoint. The global service has two endpoints, the cluster1 pod and the cluster2 network gateway, so ztunnel sent all four global calls to cluster2. cluster2 has no quarantine, so it served them. In this workshop the cluster1 pod stayed out of rotation for about two minutes after the last rejection.

> **A quarantine in one cluster leaks through global-service failover.** The same health-based failover that keeps productpage available during an outage also routes a blocked caller to a cluster that still allows it. A quarantine must reach every peered cluster in the same change.

Apply the same `DENY` in cluster2 and call the global hostname again:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER2 -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: quarantine
  namespace: istio-system
spec:
  action: DENY
  rules:
  - from:
    - source:
        principals:
        - cluster1.local/ns/tenant-a/sa/curl-client
EOF
sleep 3
served_by productpage.bookinfo-frontends.mesh.internal
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER2 --prefix --since=1m --tail=-1 | grep "explicitly denied" | tail -1
```

Expected output:
```
productpage.bookinfo-frontends.mesh.internal call 1: denied
productpage.bookinfo-frontends.mesh.internal call 2: denied
productpage.bookinfo-frontends.mesh.internal call 3: denied
productpage.bookinfo-frontends.mesh.internal call 4: denied
[pod/ztunnel-k82tv/istio-proxy] 2026-10-12T23:09:38.474613Z	error	access	connection complete	src.addr=10.244.2.56:52114 src.workload="curl-client" src.namespace="tenant-a" src.identity="spiffe://cluster1.local/ns/tenant-a/sa/curl-client" dst.addr=10.244.2.42:15008 dst.hbone_addr=productpage.bookinfo-frontends.mesh.internal:9080 dst.service="productpage.bookinfo-frontends.mesh.internal" dst.workload="productpage-v1-59c74584cf-pxvqb" dst.namespace="bookinfo-frontends" dst.identity="spiffe://cluster2.local/ns/bookinfo-frontends/sa/bookinfo-productpage" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/quarantine"
```

`explicitly denied by: istio-system/quarantine` names the policy that blocked the call in cluster2. `src.addr` is the cluster2 east-west gateway, and `src.workload="curl-client"` has no pod suffix, because cluster2 knows the caller only through peering. Treat a quarantine as a fleet-wide change: push the `DENY` to every peered cluster from the same pipeline.

> **Note:** Authorization stops the mesh traffic. It does not stop the pod from reaching non-mesh destinations, such as the Kubernetes API or the internet. Pair it with a `NetworkPolicy` from your CNI (for example a Cilium policy that selects the quarantined pods) when you need L3 isolation too. Flannel, the CNI in the vind clusters this lab was validated on, does not enforce `NetworkPolicy`.

## Cleanup

Lift the quarantine and remove the `tenant-a` access grant in both clusters:
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  kubectl delete authorizationpolicy quarantine -n istio-system --context $context --ignore-not-found
  kubectl delete -f auth-policy/productpage-tenant-a-auth.yaml --context $context --ignore-not-found
done
```

Remove the `tenant-a` namespace:
```bash
kubectl delete namespace tenant-a --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

The deny-all baseline, the four Bookinfo allow policies and the `STRICT` PeerAuthentication stay in place for the rest of the workshop. Later labs add the policies their own workloads need, the same way a team would in production. Lab `019` removes them.

## Next Steps
At this point we have completed the following objectives:
- Applied a deny-all baseline in both clusters, then allowed each Bookinfo hop by SPIFFE identity
- Listed each cluster's trust domain explicitly in policy, and saw failover fail when a cluster trusted only itself
- Required mTLS mesh-wide with a `STRICT` PeerAuthentication
- Quarantined a single suspect pod by removing it from the mesh
- Quarantined a whole identity in every cluster with a root-namespace `DENY` policy

In the next step `008` we will add a waypoint for L7 policy and traffic management
