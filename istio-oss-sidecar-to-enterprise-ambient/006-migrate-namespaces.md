# Migrate Namespaces from Sidecar to Ambient

# Objectives
- Validate the mixed state left by lab `005`: `bookinfo-backends` on ambient (`1/1`), `productpage` on its sidecar (`2/2`)
- Remove the sidecar injection label from `bookinfo-frontends`
- Enable ambient mode on `bookinfo-frontends`
- Restart `productpage` to remove its sidecar container
- Validate every bookinfo workload now shows ambient (HBONE, `1/1` pods)
- Confirm the application is still accessible

## Prerequisites
- This lab assumes you have completed labs `001`–`005`
- Solo Istio Ambient is installed (istiod, istio-cni, ztunnel all running)
- `bookinfo-backends` is already in ambient mode (lab `005`)

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
```

## Pre-Migration Check

Before migrating, confirm the starting point. Lab `005` moved `bookinfo-backends` to ambient and left `productpage` on its sidecar. The `zc workloads` command lists the workloads ztunnel knows about:

```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|bookinfo"
```

Expected output:
```
NAMESPACE          POD NAME                                ADDRESS     NODE     WAYPOINT PROTOCOL NETWORK NETWORK GATEWAY
bookinfo-backends  details-v1-56b7f5bf87-d4x22             10.244.1.20 worker-1 None     HBONE    N/A     None
bookinfo-backends  ratings-v1-5bd9df64f9-n69qh             10.244.1.21 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v1-7ccf676fc9-6dvhx             10.244.1.22 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v2-56c65cd477-plzqp             10.244.1.23 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v3-7b7c687b47-7chfq             10.244.1.24 worker-1 None     HBONE    N/A     None
bookinfo-frontends productpage-v1-68687694-28z56           10.244.1.18 worker-1 None     HBONE    N/A     None
```

`productpage` shows `HBONE` although it still has a sidecar. Lab `005` restarted it onto the Solo proxy, which speaks HBONE to ambient workloads. The `PROTOCOL` column stays `HBONE` through this lab, so watch the `READY` column instead.

Also confirm `productpage` still shows `2/2 READY` (app + sidecar) and the backends show `1/1`:
```bash
kubectl get pods -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
kubectl get pods -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1
```

## Step 1 — Remove Sidecar Injection Labels

Remove the `istio-injection=enabled` label from `bookinfo-frontends`. This stops new pods from receiving sidecar injection, but does **not** affect currently running pods:

```bash
kubectl label namespace bookinfo-frontends istio-injection- --context $KUBECONTEXT_CLUSTER1
```

Verify the label is removed:
```bash
kubectl get namespace bookinfo-frontends --show-labels --context $KUBECONTEXT_CLUSTER1
```

## Step 2 — Enable Ambient Mode

Label `bookinfo-frontends` for ambient enrollment. ztunnel will begin intercepting and securing traffic for any new pods in the namespace:

```bash
kubectl label namespace bookinfo-frontends istio.io/dataplane-mode=ambient --context $KUBECONTEXT_CLUSTER1
```

## Step 3 — Restart Pods to Remove Sidecars

The running `productpage` pod still has the Envoy sidecar container. It was injected before the label change. Restart the deployments to get fresh pods without sidecars:

```bash
kubectl rollout restart deployment -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
```

Wait for the rollout to complete:
```bash
for deploy in $(kubectl get deploy -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "Waiting for frontend deployment '$deploy'..."
  kubectl rollout status deploy/"$deploy" -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
done
```

## Validate Ambient Enrollment

**Key observation:** Pods now show `1/1 READY` — the sidecar container is gone. mTLS is handled transparently by ztunnel at the node level:

```bash
kubectl get pods -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
kubectl get pods -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
NAME                             READY   STATUS    RESTARTS   AGE
productpage-v1-<hash>            1/1     Running   0          30s

NAME                             READY   STATUS    RESTARTS   AGE
details-v1-<hash>                1/1     Running   0          20m
ratings-v1-<hash>                1/1     Running   0          20m
reviews-v1-<hash>                1/1     Running   0          20m
reviews-v2-<hash>                1/1     Running   0          20m
reviews-v3-<hash>                1/1     Running   0          20m
```

Now check the workload protocol with `solo-istioctl`:
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|bookinfo"
```

Expected output. The new `productpage` pod is on ztunnel, so every bookinfo workload is now in ambient:
```
NAMESPACE          POD NAME                                ADDRESS     NODE     WAYPOINT PROTOCOL NETWORK NETWORK GATEWAY
bookinfo-backends  details-v1-56b7f5bf87-d4x22             10.244.1.20 worker-1 None     HBONE    N/A     None
bookinfo-backends  ratings-v1-5bd9df64f9-n69qh             10.244.1.21 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v1-7ccf676fc9-6dvhx             10.244.1.22 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v2-56c65cd477-plzqp             10.244.1.23 worker-1 None     HBONE    N/A     None
bookinfo-backends  reviews-v3-7b7c687b47-7chfq             10.244.1.24 worker-1 None     HBONE    N/A     None
bookinfo-frontends productpage-v1-6f78d6645b-wtchb         10.244.1.26 worker-1 None     HBONE    N/A     None
```

`HBONE` (HTTP-Based Overlay Network Encapsulation) is the ambient mTLS tunnel protocol used by ztunnel. This confirms that all pod-to-pod traffic is now encrypted via ztunnel — no sidecar required.

## Observe ztunnel Intercepting Traffic

Generate a request to the application and inspect ztunnel logs to confirm it is intercepting and securing traffic. Open a second terminal and start tailing the ztunnel logs:

```bash
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 -f --prefix
```

In your original terminal, send a request through the ingress gateway:
```bash
SVC=$(kubectl -n istio-system get svc ingress-istio --context $KUBECONTEXT_CLUSTER1 --no-headers | awk '{ print $4 }')
curl http://$SVC/productpage -s -o /dev/null -w "%{http_code}"
```

In the ztunnel log output you should see access log entries for each hop in the bookinfo call chain. The logs from a single page load look like this:

```
[pod/ztunnel-<hash>/istio-proxy] info http access request complete src.addr=10.42.0.18:39974 src.workload="ingress-istio-<hash>" src.namespace="istio-system" src.identity="spiffe://cluster.local/ns/istio-system/sa/ingress-istio" dst.addr=10.42.0.21:15008 dst.hbone_addr=10.42.0.21:9080 dst.service="productpage.bookinfo-frontends.svc.cluster.local" dst.workload="productpage-v1-<hash>" dst.namespace="bookinfo-frontends" dst.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage" direction="inbound" method=GET path="/productpage" protocol=HTTP1 response_code=200

[pod/ztunnel-<hash>/istio-proxy] info http access request complete src.addr=10.42.0.21:60992 src.workload="productpage-v1-<hash>" src.namespace="bookinfo-frontends" src.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage" dst.addr=10.42.0.26:15008 dst.hbone_addr=10.42.0.26:9080 dst.service="details.bookinfo-backends.svc.cluster.local" dst.workload="details-v1-<hash>" dst.namespace="bookinfo-backends" dst.identity="spiffe://cluster.local/ns/bookinfo-backends/sa/bookinfo-details" direction="inbound" method=GET path="/details/0" protocol=HTTP1 response_code=200

[pod/ztunnel-<hash>/istio-proxy] info http access request complete src.addr=10.42.0.21:51018 src.workload="productpage-v1-<hash>" src.namespace="bookinfo-frontends" src.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage" dst.addr=10.42.0.26:15008 dst.hbone_addr=10.42.0.26:9080 dst.service="details.bookinfo-backends.svc.cluster.local" dst.workload="details-v1-<hash>" dst.namespace="bookinfo-backends" dst.identity="spiffe://cluster.local/ns/bookinfo-backends/sa/bookinfo-details" direction="outbound" method=GET path="/details/0" protocol=HTTP1 response_code=200

[pod/ztunnel-<hash>/istio-proxy] info http access request complete src.addr=10.42.0.21:60164 src.workload="productpage-v1-<hash>" src.namespace="bookinfo-frontends" src.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage" dst.addr=10.42.0.25:15008 dst.hbone_addr=10.42.0.25:9080 dst.service="reviews.bookinfo-backends.svc.cluster.local" dst.workload="reviews-v1-<hash>" dst.namespace="bookinfo-backends" dst.identity="spiffe://cluster.local/ns/bookinfo-backends/sa/bookinfo-reviews" direction="inbound" method=GET path="/reviews/0" protocol=HTTP1 response_code=200

[pod/ztunnel-<hash>/istio-proxy] info http access request complete src.addr=10.42.0.21:43888 src.workload="productpage-v1-<hash>" src.namespace="bookinfo-frontends" src.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage" dst.addr=10.42.0.25:15008 dst.hbone_addr=10.42.0.25:9080 dst.service="reviews.bookinfo-backends.svc.cluster.local" dst.workload="reviews-v1-<hash>" dst.namespace="bookinfo-backends" dst.identity="spiffe://cluster.local/ns/bookinfo-backends/sa/bookinfo-reviews" direction="outbound" method=GET path="/reviews/0" protocol=HTTP1 response_code=200
```

### Reading the log fields

**`src.identity` and `dst.identity`** — these are the SPIFFE workload identities ztunnel has cryptographically verified on each end of the mTLS connection. Both are present on every entry — ztunnel knows the identity of both the source and destination for every connection:

```
src.identity="spiffe://cluster.local/ns/bookinfo-frontends/sa/bookinfo-productpage"
dst.identity="spiffe://cluster.local/ns/bookinfo-backends/sa/bookinfo-details"
```

The format is `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`. ztunnel minted and verified these X.509 certificates for every hop — productpage proved it is `bookinfo-productpage` in `bookinfo-frontends`, and details proved it is `bookinfo-details` in `bookinfo-backends`. Neither workload has a sidecar; the cryptographic identity comes entirely from ztunnel.

**`dst.hbone_addr` and port `15008`** — `dst.addr` points to port `15008`, which is ztunnel's HBONE listener. This is the encrypted tunnel endpoint. `dst.hbone_addr` is the actual pod IP and application port the traffic is forwarded to after decryption.

**`direction="inbound"` vs `direction="outbound"`** — ztunnel logs both sides of every connection. You will see a pair of entries for each hop: the outbound entry (source side, encrypting the traffic) and the inbound entry (destination side, decrypting and forwarding to the pod). On a single-node cluster both entries appear in the same ztunnel log; on multi-node clusters they appear in the ztunnel logs on their respective nodes.

These log fields are the evidence that ztunnel is providing zero-trust mTLS between every service pair in the call chain — with cryptographic workload identity, and no application changes.

## Validate Application Still Works

Confirm the application is still accessible. The migration should be transparent to end users:

```bash
SVC=$(kubectl -n istio-system get svc ingress-istio --context $KUBECONTEXT_CLUSTER1 --no-headers | awk '{ print $4 }')
echo http://$SVC/productpage
curl http://$SVC/productpage | grep -o "<title>.*</title>"
```

Or use port-forward if no LoadBalancer:
```bash
kubectl port-forward svc/productpage -n bookinfo-frontends 9080:9080 --context $KUBECONTEXT_CLUSTER1
curl http://localhost:9080/productpage | grep -o "<title>.*</title>"
```

The Bookinfo application should respond normally. The migration from sidecar to ambient is complete.

## Migration Summary

| | Before Migration | After Migration |
|---|---|---|
| **Pod readiness** | `2/2` (app + sidecar) | `1/1` (app only) |
| **mTLS enforcement** | Per-pod Envoy sidecar | Node-level ztunnel DaemonSet |
| **Protocol** | TCP with the community sidecar, HBONE with the Solo sidecar from lab `005` | HBONE (ztunnel handles mTLS) |
| **Namespace label** | `istio-injection=enabled` | `istio.io/dataplane-mode=ambient` |
| **Resource overhead** | Envoy per pod | Shared ztunnel per node |

## Next Steps

At this point we have completed the following objectives:
- Confirmed the mixed sidecar and ambient state left by lab `005`
- Removed the sidecar injection label from `bookinfo-frontends`
- Enabled ambient mode on `bookinfo-frontends`
- Restarted `productpage`, which now shows `1/1 READY` (no sidecar)
- Confirmed HBONE protocol via `solo-istioctl zc workloads`
- Validated the application is still accessible

**Phase 2 (Migration) is complete.** In the next step `007` we will establish zero-trust access control using Istio AuthorizationPolicy enforced by ztunnel.
