# Migrate One Namespace at a Time with Sidecar and Ambient Interop

# Objectives
- Restart sidecar workloads and the ingress gateway so they run the Solo `proxyv2` image
- Move `bookinfo-backends` to ambient while `productpage` keeps its sidecar
- Deploy a waypoint for `bookinfo-backends` and put an L7 route on it
- Confirm that a sidecar client sends its requests through the waypoint with the default ambient install
- Label a Service with `istio.io/ingress-use-waypoint=true` so the ingress gateway also uses the waypoint
- Review the policies that can apply twice while a workload has both a sidecar and a waypoint

## Prerequisites
- This lab assumes you have completed labs `001`–`004`
- Solo Istio Ambient is installed (istiod, istio-cni, ztunnel all running) and Bookinfo pods still show `2/2 READY`

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
```

## Background

A mesh with many teams moves to ambient over weeks or months. During that time some namespaces run sidecars and others run ambient, and the L7 rules for each service must keep working for callers on both sides.

In ambient, L7 rules live on the waypoint of the destination service. Sidecars and ingress gateways are Envoy proxies that apply routing on the client side. In the community distribution they reach ambient pods over HBONE but send nothing to waypoints. A sidecar client that calls a waypoint-backed service goes straight to the pod, so the waypoint's routes and L7 policies skip that request. To keep L7 behavior during the migration, a team keeps two copies of each rule (a VirtualService for sidecar clients and an HTTPRoute on the waypoint) or migrates every caller first.

The Solo distribution sends both kinds of Envoy client to the waypoint:

| Client | Community Istio | Solo Istio |
|---|---|---|
| Sidecar calling a service that has a waypoint | Goes direct to the pod. Waypoint rules skip the request. | Detects the waypoint, skips its own client-side rules (VirtualServices) and sends the request to the waypoint. Works with the default ambient install. |
| Ingress gateway calling a service that has a waypoint | Goes direct to the pod. Waypoint rules skip the request. | Sends the request to the waypoint when the Service has the `istio.io/ingress-use-waypoint=true` label. |

With interop, you move one namespace at a time: move it, check it, then move the next one, and roll back a single namespace if something breaks. You write each L7 rule once, on the waypoint of the destination, and it applies to ambient callers, sidecar callers and the ingress gateway. A destination team can adopt a waypoint before its callers migrate.

The settings are the ambient settings from lab `004` (Solo images at Istio 1.25 or later, `profile=ambient` on istiod and istio-cni, ztunnel, Gateway API CRDs) plus the ingress label. Each sidecar needs one restart onto the Solo `proxyv2` image.

> **Solo Enterprise feature:** Waypoint interop for sidecars and ingress gateways is part of the Solo distribution of Istio. For a large mesh, the Solo ambient migration tool checks the prerequisites, plans the phases and flags policies that need changes. See the [ambient migration guide](https://docs.solo.io/istio/1.30.x/ambient/setup/install/migrate/).

This lab moves `bookinfo-backends` to ambient and leaves `productpage` and the ingress gateway on Envoy. The target state:

```
                       /productpage
client --> ingress-istio ------------> productpage            bookinfo-backends (ambient)
           (Envoy)                     (sidecar)             +---------------------------+
              |                            |                 |                           |
              |                            +-- /reviews ---->|  waypoint                 |
              |                                              |  HTTPRoute: reviews-stable|
              +---- /reviews (ingress-use-waypoint=true) --->|      |                    |
                                                             |      v                    |
                                                             |  reviews-v3               |
                                                             +---------------------------+
```

## Step 1: Pick Up the Solo `proxyv2` Image

Lab `004` upgraded the control plane, but OSS istiod injected the running sidecars, and they still run the community proxy. The waypoint interop logic is in the Solo proxy and in the config Solo istiod sends to it, so each sidecar client restarts once.

Istio injects the sidecar as a Kubernetes native sidecar, so the `istio-proxy` container is listed under `initContainers`. Check its image on `productpage`:
```bash
kubectl get pod -n bookinfo-frontends -l app=productpage --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.initContainers[?(@.name=="istio-proxy")].image}{"\n"}{end}'
```

Expected output (the community image):
```
productpage-v1-59c74584cf-p5cqd  docker.io/istio/proxyv2:1.29.5
```

`bookinfo-frontends` still has the `istio-injection=enabled` label, so a restart injects a new sidecar from Solo istiod:
```bash
kubectl rollout restart deployment -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
```

Check the image again:
```bash
kubectl get pod -n bookinfo-frontends -l app=productpage --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.initContainers[?(@.name=="istio-proxy")].image}{"\n"}{end}'
```

Expected output:
```
productpage-v1-68687694-28z56  us-docker.pkg.dev/soloio-img/istio/proxyv2:1.30.5-solo-distroless
```

If a second line shows the community image, the old pod is still terminating. Run the check again after a few seconds. The new pod shows `2/2 READY`: it is a sidecar workload on the Solo proxy.

Now check the ingress gateway. Istiod manages the `ingress-istio` Deployment and re-rendered it during the upgrade in lab `004`, but the result can still carry the community image:
```bash
kubectl get pod -n istio-system -l gateway.networking.k8s.io/gateway-name=ingress --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[?(@.name=="istio-proxy")].image}{"\n"}{end}'
```

Expected output:
```
ingress-istio-65cbb7bfff-vwpmk  docker.io/istio/proxyv2:1.29.5-distroless
```

Restart it so Solo istiod renders it again:
```bash
kubectl rollout restart deploy/ingress-istio -n istio-system --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/ingress-istio -n istio-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1

kubectl get pod -n istio-system -l gateway.networking.k8s.io/gateway-name=ingress --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[?(@.name=="istio-proxy")].image}{"\n"}{end}'
```

Expected output:
```
ingress-istio-66b8d4869b-58zqt  us-docker.pkg.dev/soloio-img/istio/proxyv2:1.30.5-solo-distroless
```

## Step 2: Move `bookinfo-backends` to Ambient

Move the backend namespace. `productpage` keeps its sidecar until lab `006`:
```bash
kubectl label namespace bookinfo-backends istio-injection- --context $KUBECONTEXT_CLUSTER1
kubectl label namespace bookinfo-backends istio.io/dataplane-mode=ambient --context $KUBECONTEXT_CLUSTER1

kubectl rollout restart deployment -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1
for deploy in $(kubectl get deploy -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[*].metadata.name}'); do
  echo "Waiting for backend deployment '$deploy'..."
  kubectl rollout status deploy/"$deploy" -n bookinfo-backends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
done
```

The `READY` column shows which workloads still have a sidecar:
```bash
kubectl get pods -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
kubectl get pods -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
NAME                            READY   STATUS    RESTARTS   AGE
productpage-v1-68687694-28z56   2/2     Running   0          30s

NAME                          READY   STATUS    RESTARTS   AGE
details-v1-56b7f5bf87-d4x22   1/1     Running   0          12s
ratings-v1-5bd9df64f9-n69qh   1/1     Running   0          12s
reviews-v1-7ccf676fc9-6dvhx   1/1     Running   0          12s
reviews-v2-56c65cd477-plzqp   1/1     Running   0          12s
reviews-v3-7b7c687b47-7chfq   1/1     Running   0          12s
```

Now check what ztunnel knows about each workload:
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|bookinfo|ingress"
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
istio-system       ingress-istio-66b8d4869b-58zqt          10.244.1.19 worker-1 None     TCP      N/A     None
```

`productpage` shows `HBONE` although it still has its sidecar. The Solo sidecar accepts and sends HBONE itself, so ambient workloads reach it over the same mTLS tunnel they use with each other. Use the `READY` column, not `PROTOCOL`, to tell sidecar workloads from ambient ones during the migration.

Confirm the page still renders through the ingress gateway. `productpage` (sidecar) calls `details` and `reviews` (ambient) over HBONE:
```bash
SVC=$(kubectl -n istio-system get svc ingress-istio --context $KUBECONTEXT_CLUSTER1 --no-headers | awk '{ print $4 }')
if [[ "$SVC" == "<pending>" || -z "$SVC" || "$SVC" == "<none>" ]]; then
  echo "⚠️  No external LoadBalancer IP available. See the 'No LoadBalancer? Use Port-Forward' note below."
else
  curl -s http://$SVC/productpage | grep -o "<title>.*</title>"
fi
```

Expected output:
```
<title>Simple Bookstore App</title>
```

> **No LoadBalancer? Use Port-Forward.** This lab tests the ingress gateway, so port-forward to the gateway, not to `productpage`. Run this in a second terminal and set `SVC` in the first:
> ```bash
> kubectl port-forward -n istio-system svc/ingress-istio 8080:80 --context $KUBECONTEXT_CLUSTER1
> ```
> ```bash
> export SVC=localhost:8080
> ```

## Step 3: Add a Waypoint and an L7 Route

The `reviews` team wants all traffic on `reviews-v3` (red stars). In a sidecar mesh that rule is a VirtualService that each client sidecar applies. In ambient it is an HTTPRoute on the waypoint of `bookinfo-backends`.

Deploy the waypoint and bind the namespace to it:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
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
kubectl rollout status deploy/waypoint -n bookinfo-backends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1

kubectl label namespace bookinfo-backends istio.io/use-waypoint=waypoint --context $KUBECONTEXT_CLUSTER1
```

Turn on access logs for the waypoint so you can see which requests pass through it:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: waypoint-access-logging
  namespace: bookinfo-backends
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  accessLogging:
  - providers:
    - name: envoy
EOF
```

Apply the `reviews-stable` Service (selects `reviews-v3` only) and an HTTPRoute that sends all `reviews` traffic to it:
```bash
kubectl apply -f bookinfo/bookinfo-waypoint-services.yaml --context $KUBECONTEXT_CLUSTER1

kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: bookinfo-backends
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-stable
      port: 9080
EOF
```

## Step 4: Sidecar Client to Waypoint

`productpage` has a sidecar and the config it had in Step 1. Call `reviews` ten times from inside the pod and print which pod answered. The `productpage` image has no `curl`, so the call uses Python:
```bash
kubectl exec deploy/productpage-v1 -c productpage -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 -- \
  python3 -c "
import json, urllib.request
for i in range(10):
    print(json.load(urllib.request.urlopen('http://reviews.bookinfo-backends:9080/reviews/0'))['podname'])"
```

Expected output (each request lands on `reviews-v3`):
```
reviews-v3-7b7c687b47-7chfq
reviews-v3-7b7c687b47-7chfq
reviews-v3-7b7c687b47-7chfq
...
```

Solo istiod told the sidecar that `reviews` has a waypoint. Look at the endpoints the sidecar holds for `reviews`, and at the waypoint pod address:
```bash
PRODUCTPAGE_POD=$(kubectl get pod -n bookinfo-frontends -l app=productpage --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].metadata.name}')
./solo-istioctl proxy-config endpoints $PRODUCTPAGE_POD.bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 \
  --cluster "outbound|9080||reviews.bookinfo-backends.svc.cluster.local"

kubectl get pod -n bookinfo-backends -l gateway.networking.k8s.io/gateway-name=waypoint --context $KUBECONTEXT_CLUSTER1 -o wide
```

Expected output (the address differs on your machine):
```
ENDPOINT                                        STATUS      OUTLIER CHECK     CLUSTER
envoy://connect_originate/10.244.1.25:15008     HEALTHY     OK                outbound|9080||reviews.bookinfo-backends.svc.cluster.local

NAME                        READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
waypoint-578ddb66c5-ks26z   1/1     Running   0          40s   10.244.1.25   worker-1   <none>           <none>
```

The sidecar has one endpoint for `reviews`: the waypoint pod on its HBONE port `15008`. The `reviews` pods are absent from that list. Check the waypoint access log for the ten requests:
```bash
kubectl logs deploy/waypoint -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 | grep '"GET /reviews'
```

Expected output (one line per request, abridged):
```
[2026-10-14T17:48:57.301Z] "GET /reviews/0 HTTP/1.1" 200 - via_upstream - "-" 0 442 9 8 "-" "Python-urllib/3.12" "..." "reviews.bookinfo-backends:9080" "envoy://connect_originate/10.244.1.24:9080" inbound-vip|9080|http|reviews-stable.bookinfo-backends.svc.cluster.local ...
```

`inbound-vip|9080|http|reviews-stable...` is the backend the HTTPRoute picked. Reload the product page in a browser a few times. The reviews show red stars on each load, because `productpage` builds the page from the same `reviews` calls.

> **Client-side VirtualServices stop applying.** When a sidecar sends a request to a waypoint, it skips its own VirtualService for that host. Move the client-side routing rules for a service to its waypoint before you bind the waypoint. Sidecar clients stop applying those rules when the binding takes effect.

## Step 5: Ingress Gateway to Waypoint

A gateway applies its own route to choose the destination, so by default it sends the request to the destination pods and skips the waypoint. Expose `reviews` on the ingress gateway under `/reviews` to see this:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-ingress
  namespace: bookinfo-backends
spec:
  parentRefs:
  - name: ingress
    namespace: istio-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /reviews
    backendRefs:
    - name: reviews
      port: 9080
EOF
```

Wait a few seconds for the route to reach the gateway, then send ten requests through it:
```bash
sleep 3
for i in $(seq 1 10); do
  curl -s http://$SVC/reviews/0 | grep -o 'reviews-v[0-9]' | head -1
done
```

Expected output (a mix of versions, because the gateway skips the waypoint route):
```
reviews-v2
reviews-v1
reviews-v1
reviews-v3
reviews-v3
...
```

Label the `reviews` Service so the ingress gateway sends its traffic to the waypoint:
```bash
kubectl label svc reviews -n bookinfo-backends istio.io/ingress-use-waypoint=true --context $KUBECONTEXT_CLUSTER1
```

Wait a few seconds for istiod to push the change to the gateway, then send ten requests again:
```bash
sleep 3
for i in $(seq 1 10); do
  curl -s http://$SVC/reviews/0 | grep -o 'reviews-v[0-9]' | head -1
done
```

Expected output:
```
reviews-v3
reviews-v3
reviews-v3
...
```

The waypoint log now has the gateway's requests too, with `curl` as the user agent:
```bash
kubectl logs deploy/waypoint -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 | grep '"GET /reviews' | grep curl
```

The waypoint applies one route to the ingress gateway, the sidecar in `productpage` and ambient callers. To cover each Service in a namespace, put the label on the namespace. A label on a Service wins over a label on its namespace, and `istio.io/ingress-use-waypoint=false` on a Service turns it off for that Service.

With the label in place, keep the gateway route minimal (pick the backend Service) and put the other routing and policy on the waypoint. Keep edge policies, such as user authentication or rate limits for external clients, on the gateway.

## Watch Out for Policies That Apply Twice

During a migration, a destination pod can have a sidecar and also sit behind a waypoint. This happens when you bind a waypoint to a namespace that still has sidecar pods. A request then passes the waypoint and the sidecar inbound, and policies configured at both places apply twice:

| Configuration | Effect when applied at the waypoint and the sidecar |
|---|---|
| AuthorizationPolicy | Works. Both checks must pass. |
| AuthorizationPolicy with a `CUSTOM` extension provider | Breaks. A waypoint allows one provider for all the workloads it serves, so a workload can get the wrong provider. |
| Global rate limit | Each request counts twice, so the effective quota is half. Double the quota for the overlap period. |
| Local rate limit | Works. Each proxy counts on its own. |
| PeerAuthentication with `DISABLE` | Breaks. Ambient always uses mTLS (HBONE) and ignores `DISABLE`. Use `STRICT`. |
| RequestAuthentication with `forwardOriginalToken: false` (the default) | Breaks. The waypoint removes the token after it validates it, then the sidecar rejects the request. Set `forwardOriginalToken: true`. |

The overlap ends when the last sidecar in the namespace is gone and you delete the old sidecar-inbound policies.

> **Ambient egress gateways and sidecars.** Sidecars cannot route through the `solo-ztunnel-egress` gateway. While sidecars run in the mesh, add the `solo.io/sidecar-skip-waypoint: "true"` annotation to each ServiceEntry that has an `istio.io/use-waypoint` label. Ambient workloads keep using the waypoint, and sidecars send egress traffic the way they did before. Lab `010` sets up egress after every workload is in ambient, so its ServiceEntries leave the annotation out.

## Cleanup

Remove the ingress route, the label and the waypoint route:
```bash
kubectl delete httproute reviews-ingress reviews -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl label svc reviews -n bookinfo-backends istio.io/ingress-use-waypoint- --context $KUBECONTEXT_CLUSTER1
kubectl delete -f bookinfo/bookinfo-waypoint-services.yaml --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete telemetry waypoint-access-logging -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

Remove the waypoint. Lab `008` deploys it again after the access-control policies of lab `007` are in place:
```bash
kubectl label namespace bookinfo-backends istio.io/use-waypoint- --context $KUBECONTEXT_CLUSTER1
kubectl delete gateway waypoint -n bookinfo-backends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

`bookinfo-backends` stays in ambient and `productpage` keeps its sidecar. Lab `006` moves the last namespace.

## Next Steps

At this point we have completed the following objectives:
- Restarted `productpage` and the ingress gateway onto the Solo `proxyv2` image
- Moved `bookinfo-backends` to ambient while `productpage` kept its sidecar
- Deployed a waypoint for `bookinfo-backends` with an L7 route on `reviews`
- Confirmed that the sidecar in `productpage` sent its requests through the waypoint with the default ambient install
- Labeled `reviews` with `istio.io/ingress-use-waypoint=true` so the ingress gateway also used the waypoint
- Reviewed the policies that can apply twice while a workload has both a sidecar and a waypoint

In the next step `006` we will move `bookinfo-frontends`, the last sidecar namespace, to ambient.
