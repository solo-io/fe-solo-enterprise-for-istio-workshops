# Convert ingress-nginx and Istio Ingress Objects to Gateway API

# Objectives
- Convert a team's ingress-nginx `Ingress` objects to Gateway API with `ingress2gateway`
- Review the output: fix what the tool converted differently, and rewrite what it could not convert
- Replace a capture-group rewrite with a prefix rewrite, and rewrite capture groups with an agentgateway policy when no prefix rewrite fits
- Serve a gRPC backend through a `GRPCRoute`, with mesh mTLS and an identity policy in place of backend TLS annotations
- Convert a sidecar-era Istio `Gateway` and `VirtualService`, and catch the fields that the conversion changes
- Test a converted hostname on the new gateway before DNS moves, and gate conversions in CI

## Prerequisites
- This lab assumes you have completed setup from labs `000-016`

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export INGRESS2GATEWAY_VERSION=v1.2.0
[ -n "$INGRESS_ADDR" ] || echo "WARNING: INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

## Background

[`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) is the Kubernetes SIG Network tool that reads `Ingress` objects, and some provider-specific resources, and prints Gateway API resources. It reads from a cluster or from files. This lab uses files, the way a team would run it against its own Git repository. Its `--emitter agentgateway` option targets agentgateway, the gateway from lab `005`.

The conversion is a starting point. The tool translates the annotations it knows, prints a warning for each one it cannot translate, and emits a new `Gateway` per namespace. A reviewer then makes three kinds of change:

| Change | Example in this lab |
|---|---|
| Attach routes to the shared platform Gateway instead of the generated one | `parentRefs` points at `agentgateway-system/ingress` |
| Rewrite what the tool flagged as unsupported | A `rewrite-target: /$2` capture-group rewrite |
| Correct what the tool converted faithfully but you do not want | A regex match that ingress-nginx applies to every path of a host |

The sample objects are in `ingress-nginx/`:

| File | What it holds |
|---|---|
| `team-bookinfo.yaml` | Host routing, a 20 percent canary, and a `/store` prefix strip written as a regex rewrite |
| `team-grpc.yaml` | A gRPC backend with `backend-protocol: GRPCS` and a client certificate for backend mTLS |
| `istio-sidecar-ingress.yaml` | An Istio `Gateway` and `VirtualService` from a sidecar-era install |

## Install ingress2gateway

Download the release binary into the workshop directory:
```bash
OS=$(uname -s)
ARCH=$(uname -m | sed -E 's/aarch64/arm64/')
curl -sSL "https://github.com/kubernetes-sigs/ingress2gateway/releases/download/${INGRESS2GATEWAY_VERSION}/ingress2gateway_${OS}_${ARCH}.tar.gz" \
  | tar xzf - ingress2gateway
./ingress2gateway version
```

Expected output:
```
ingress2gateway version: 1.2.0
Built with Go version: go1.25.11
```

## Convert the Bookinfo Ingress Objects

Look at the source objects, then convert them. The tool prints warnings on stderr and the resources on stdout:
```bash
cat ingress-nginx/team-bookinfo.yaml
./ingress2gateway print --providers ingress-nginx --emitter agentgateway --input-file ingress-nginx/team-bookinfo.yaml --no-color
```

Expected output (abridged):
```
┌─ WARN  ────────────────────────────────────────
│  Failed to apply metadata.annotations."nginx.ingress.kubernetes.io/rewrite-target" from rewrite-target from Ingress bookinfo-frontends/bookinfo-store: Path rewrites with capture group references are not supported
│  source: AGENTGATEWAY
│  object: HTTPRoute: bookinfo-frontends/bookinfo-bookinfo-example-com
└─
┌─ WARN  ────────────────────────────────────────
│  Ingress NGINX serves TLS traffic for host "bookinfo.example.com" with a self-signed certificate. This behavior will not be translated and the host will not be accessible via HTTPS.
│  source: INGRESS-NGINX
└─
┌─ INFO  ────────────────────────────────────────
│  Using case-insensitive regex path matches. You may want to change this.
│  source: INGRESS-NGINX
│  object: HTTPRoute: bookinfo-frontends/bookinfo-bookinfo-example-com
└─
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: nginx
  namespace: bookinfo-frontends
spec:
  gatewayClassName: agentgateway
...
kind: HTTPRoute
metadata:
  name: bookinfo-bookinfo-example-com
  namespace: bookinfo-frontends
spec:
  hostnames:
  - bookinfo.example.com
  parentRefs:
  - name: nginx
  rules:
  - backendRefs:
    - name: productpage
      port: 9080
      weight: 80
    - name: productpage-canary
      port: 9080
      weight: 20
    matches:
    - path:
        type: RegularExpression
        value: (?i)/.*
    name: rule-0
  - backendRefs:
    - name: productpage
      port: 9080
    matches:
    - path:
        type: RegularExpression
        value: (?i)/store(/|$)(.*).*
    name: rule-1
```

Review the output against the source:

- The canary annotations became weighted `backendRefs` (80 and 20), merged into the main route. That conversion is correct as is.
- The `/` path became the regex `(?i)/.*`. ingress-nginx applies `use-regex` to every path of a host once any Ingress for that host sets it, and the tool reproduces that. The team only wanted a regex for `/store`, so the reviewed route uses plain prefix matches.
- The `/store` rule kept its match and lost its rewrite. Without the rewrite, `/store/productpage` reaches productpage as `/store/productpage` and returns `404`.
- The route attaches to a new `Gateway` named `nginx` with class `agentgateway`, the open source agentgateway class. The platform already runs a shared Solo Enterprise for agentgateway Gateway, so the reviewed route attaches to `agentgateway-system/ingress`.

## Replace the Capture-Group Rewrite

The source rewrite is `path: /store(/|$)(.*)` with `rewrite-target: /$2`: drop the `/store` prefix and keep the rest. Gateway API expresses that without a regex, as a `PathPrefix` match with a `ReplacePrefixMatch` rewrite. Apply the reviewed route and the canary Service it references:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: productpage-canary
  namespace: bookinfo-frontends
spec:
  selector:
    app: productpage
  ports:
  - name: http
    port: 9080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-bookinfo-example-com
  namespace: bookinfo-frontends
spec:
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  hostnames:
  - bookinfo.example.com
  rules:
  # nginx: path /store(/|$)(.*) with rewrite-target /\$2
  - matches:
    - path:
        type: PathPrefix
        value: /store
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: productpage
      port: 9080
  # nginx: path / plus the canary Ingress with canary-weight 20
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: productpage
      port: 9080
      weight: 80
    - name: productpage-canary
      port: 9080
      weight: 20
EOF
sleep 3
```

`productpage-canary` selects the same pods as `productpage` in this lab. In a real migration it is the team's canary Deployment.

Test the converted hostname on the new gateway. Real DNS for the hostname still points at ingress-nginx during a migration, so set the `Host` header (or use `curl --resolve` for HTTPS) to reach the new gateway before DNS moves:
```bash
for P in /productpage /store/productpage; do
  curl -s -H "Host: bookinfo.example.com" -o /dev/null -w "bookinfo.example.com$P -> %{http_code}\n" http://$INGRESS_ADDR$P
done
curl -s -o /dev/null -w "other host /store/productpage -> %{http_code}\n" http://$INGRESS_ADDR/store/productpage
```

Expected output:
```
bookinfo.example.com/productpage -> 200
bookinfo.example.com/store/productpage -> 200
other host /store/productpage -> 404
```

The rewrite applies to `bookinfo.example.com` only. The `bookinfo-route` from lab `007` has no hostname, so other hosts still use it, and it has no `/store` rule.

### When No Prefix Rewrite Fits

Gateway API rewrites replace a prefix or the full path. It has no rewrite that reorders capture groups, such as `/api/(v1)/(.*)` to `/$2?version=$1`. agentgateway can: a policy on the route sets the `:path` pseudo-header from a CEL expression, and `regexReplace` takes the same capture-group references as nginx.

Deploy an echo backend, which prints the path it receives, behind an `api.example.com` route, and attach the rewrite policy to that route:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: api-echo
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: api-echo
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
        args: ["--port", "8080"]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: api-echo
spec:
  selector:
    app: echo
  ports:
  - name: http
    port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: api-echo
spec:
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  hostnames:
  - api.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api/
    backendRefs:
    - name: echo
      port: 8080
---
# nginx: path /api/(v[0-9]+)/(.*) with rewrite-target /\$2?version=\$1
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: api-version-rewrite
  namespace: api-echo
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: api
  traffic:
    transformation:
      request:
        set:
        - name: ":path"
          value: 'request.path.regexReplace("^/api/(v[0-9]+)/(.*)$", "/\$2?version=\$1")'
EOF
kubectl rollout status deploy/echo -n api-echo --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
sleep 3
curl -s -H "Host: api.example.com" http://$INGRESS_ADDR/api/v1/items/42 | grep "^URL="
```

Expected output:
```
URL=/items/42?version=v1
```

The backend received `/items/42?version=v1`. The policy applies to the `api` route only. A prefix rewrite works on any Gateway API implementation. A CEL rewrite works only on agentgateway.

## Serve gRPC with Mesh mTLS

Convert the gRPC Ingress:
```bash
./ingress2gateway print --providers ingress-nginx --emitter agentgateway --input-file ingress-nginx/team-grpc.yaml --no-color 2>&1 | grep -A2 "WARN" | grep "│  [A-Z]"
./ingress2gateway print --providers ingress-nginx --emitter agentgateway --input-file ingress-nginx/team-grpc.yaml --no-color 2>/dev/null | sed -n '/kind: GRPCRoute/,/^status:/p' | sed '$d'
```

Expected output:
```
│  GRPC support is not fully implemented. Some Ingress-NGINX GRPC behaviors may not be correctly translated, and untranslated behavior may not be notified.
│  Ingress NGINX serves TLS traffic for host "grpc.example.com" with a self-signed certificate. This behavior will not be translated and the host will not be accessible via HTTPS.
kind: GRPCRoute
metadata:
  annotations:
    gateway.networking.k8s.io/generator: ingress2gateway-1.2.0
  name: echo-grpc-grpc-example-com
  namespace: grpc-echo
spec:
  hostnames:
  - grpc.example.com
  parentRefs:
  - name: nginx
  rules:
  - backendRefs:
    - name: echo
      port: 7070
```

The tool produced a `GRPCRoute`. The output has nothing for `backend-protocol: GRPCS`, `proxy-ssl-secret` or `proxy-ssl-verify`, and no warning names them: the first warning says that untranslated gRPC behavior may go unreported. Those three annotations made ingress-nginx connect to the backend over TLS, present a client certificate, and verify the backend's certificate.

In ambient mode, the gateway reaches an enrolled backend over HBONE, which is mTLS with SPIFFE identities on both sides. That covers what the annotations did, with certificates that the mesh issues and rotates. An `AuthorizationPolicy` then takes the place of the backend's client certificate check: only the gateway's identity may connect.

Deploy a gRPC echo backend in an enrolled namespace, the reviewed `GRPCRoute`, and the policy:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: grpc-echo
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: grpc-echo
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
        args: ["--grpc", "7070", "--port", "8080", "--cluster", "cluster1"]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: grpc-echo
spec:
  selector:
    app: echo
  ports:
  - name: grpc
    port: 7070
    appProtocol: grpc
---
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: echo-grpc-grpc-example-com
  namespace: grpc-echo
spec:
  parentRefs:
  - name: ingress
    namespace: agentgateway-system
  hostnames:
  - grpc.example.com
  rules:
  - backendRefs:
    - name: echo
      port: 7070
---
# Replaces proxy-ssl-secret and proxy-ssl-verify: only the ingress gateway may connect
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: echo-from-ingress-only
  namespace: grpc-echo
spec:
  selector:
    matchLabels:
      app: echo
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster1.local/ns/agentgateway-system/sa/ingress
        - cluster2.local/ns/agentgateway-system/sa/ingress
EOF
kubectl rollout status deploy/echo -n grpc-echo --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
sleep 3
```

The echo image includes a client. Call the backend through the gateway with the `grpc.example.com` authority, then call it directly from inside its own namespace:
```bash
echo "== through the ingress gateway"
kubectl exec deploy/echo -n grpc-echo --context $KUBECONTEXT_CLUSTER1 -- \
  /usr/local/bin/client grpc://ingress.agentgateway-system:80 -H "Host: grpc.example.com" 2>&1 | grep -oE "Proto=[A-Z]+|Hostname=[^ ]+|All requests succeeded"
echo "== direct to the backend"
kubectl exec deploy/echo -n grpc-echo --context $KUBECONTEXT_CLUSTER1 -- \
  /usr/local/bin/client grpc://echo.grpc-echo:7070 > /dev/null 2>&1 && echo "allowed" || echo "denied"
sleep 2
kubectl logs -n istio-system -l app=ztunnel --context $KUBECONTEXT_CLUSTER1 --since=1m --tail=-1 \
  | grep 'dst.service="echo.grpc-echo' | grep 'direction="inbound"' | grep -v error | tail -1 \
  | grep -oE 'src.identity="[^"]+"|dst.addr=[^ ]+|dst.identity="[^"]+"|protocol=[A-Z0-9]+' | paste -s -d ' ' -
```

Expected output:
```
== through the ingress gateway
Proto=GRPC
Hostname=echo-6768cb6b65-8pw4w
All requests succeeded
== direct to the backend
denied
src.identity="spiffe://cluster1.local/ns/agentgateway-system/sa/ingress" dst.addr=10.244.1.78:15008 dst.identity="spiffe://cluster1.local/ns/grpc-echo/sa/default" protocol=HTTP2
```

The gateway reached the backend over HBONE (`15008`) with both identities verified, and the direct call was denied.

> **Backends outside the mesh.** If a backend stays outside the mesh and requires TLS or a client certificate, configure the gateway's upstream TLS for it: a Gateway API `BackendTLSPolicy` for server verification, or the `backend.tls` section of an `EnterpriseAgentgatewayPolicy`, with `caCertificateRefs` to verify the backend and `mtlsCertificateRef` for a client certificate. Enrolling the backend in the mesh replaces both.

## Convert Sidecar-Era Istio Ingress Resources

Teams that ran Istio with sidecars have `networking.istio.io` `Gateway` and `VirtualService` objects instead of `Ingress`. The tool's `istio` provider converts them. Look at the source, then convert it:
```bash
cat ingress-nginx/istio-sidecar-ingress.yaml
./ingress2gateway print --providers istio --emitter agentgateway --input-file ingress-nginx/istio-sidecar-ingress.yaml --no-color 2>&1 >/dev/null \
  | grep -o "ignoring field: .*" | sort -u
./ingress2gateway print --providers istio --emitter agentgateway --input-file ingress-nginx/istio-sidecar-ingress.yaml --no-color 2>/dev/null \
  | grep -E "name: bookinfo-idx|weight:|value: /store" | sed 's/^ *//' | sort -u
```

Expected output:
```
ignoring field: istio.Gateway[bookinfo-gateway].Server[0].Port.Name
ignoring field: istio.VirtualService[bookinfo-frontends/bookinfo].Http[2].Retries
name: bookinfo-idx-0
name: bookinfo-idx-1-prefix-match
name: bookinfo-idx-2
value: /store/
weight: 0
```

Review the output against the source:

- Every `backendRef` has `weight: 0`. Each `VirtualService` route had one destination with no weight, and the converted route gives that destination weight `0`, which sends it no traffic. Remove the field or set it to `1` before applying.
- The retry policy is gone: `ignoring field: ...Retries` names it. Add it back as a waypoint or gateway policy, or keep a `VirtualService` for the retry on the waypoint (lab `009`).
- Rule order changed meaning. The `VirtualService` checks its rules in order, so a `premium-user` request to `/store/` matched the header rule first. The tool writes one `HTTPRoute` per rule, and Gateway API picks the longest path match before it compares headers, so the same request now matches the `/store/` rule.
- The provider reads `networking.istio.io/v1beta1` and `v1alpha3`. It skips `networking.istio.io/v1` objects with a log line and converts nothing. The sample file uses `v1beta1` for that reason: change the version in a copy of your files before you convert them.

For the in-mesh resources of a sidecar install, the ambient equivalents are:

| Sidecar-era resource | Ambient equivalent |
|---|---|
| `VirtualService` for mesh traffic | `HTTPRoute` with a Service `parentRef`, served by a waypoint (lab `009`) |
| `DestinationRule` | Unchanged. Waypoints and gateways apply it |
| `AuthorizationPolicy` with L4 rules | Unchanged with `selector`. ztunnel enforces it (lab `008`) |
| `AuthorizationPolicy` with L7 rules | `targetRefs` to the Service, enforced by a waypoint (lab `009`) |
| `RequestAuthentication` | `targetRefs` to the gateway or the waypoint |
| `PeerAuthentication` | Only `STRICT` changes behavior (lab `008`) |
| `ServiceEntry` | Unchanged. Add `istio.io/use-waypoint` to send it through an egress waypoint (lab `016`) |

The [sidecar to ambient migration workshop](../istio-oss-sidecar-to-enterprise-ambient/README.md) moves a running sidecar mesh to ambient namespace by namespace.

## Migrate One Team at a Time

A per-team migration repeats the same steps for each team's hostnames, while ingress-nginx keeps serving everything else:

1. The team runs `ingress2gateway` against its own manifests in CI, and reviews the output as above.
2. The team commits the reviewed routes, attached to the shared Gateway, with `parentRefs` to `agentgateway-system/ingress`.
3. The team tests each hostname against the new gateway address with the `Host` header or `curl --resolve`, as above, while DNS still points at ingress-nginx.
4. The platform team moves DNS for those hostnames to the new gateway. Moving back is the same DNS change.
5. The team deletes its `Ingress` objects once the old controller no longer receives traffic for them.

Gate step 1 on the tool's warnings. The tool writes warnings to stderr, so a CI job can count them and fail until each one has a reviewed answer:
```bash
WARNINGS=$(./ingress2gateway print --providers ingress-nginx --emitter agentgateway --input-file ingress-nginx/team-bookinfo.yaml --no-color 2>&1 >/dev/null | grep -c "WARN")
echo "ingress2gateway warnings: $WARNINGS"
[ "$WARNINGS" -eq 0 ] || echo "Review each warning and record how the reviewed route handles it before merging."
```

Expected output:
```
ingress2gateway warnings: 2
Review each warning and record how the reviewed route handles it before merging.
```

## Cleanup

Remove the converted routes, the canary Service, the gRPC and API backends and the tool binary:
```bash
kubectl delete httproute bookinfo-bookinfo-example-com -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete svc productpage-canary -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace grpc-echo api-echo --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
rm -f ingress2gateway
```

## Next Steps
At this point we have completed the following objectives:
- Converted a team's ingress-nginx `Ingress` objects to Gateway API with `ingress2gateway`
- Reviewed the output: fixed what the tool converted differently, and rewrote what it could not convert
- Replaced a capture-group rewrite with a prefix rewrite, and rewrote capture groups with an agentgateway policy where no prefix rewrite fits
- Served a gRPC backend through a `GRPCRoute`, with mesh mTLS and an identity policy in place of backend TLS annotations
- Converted a sidecar-era Istio `Gateway` and `VirtualService`, and caught the fields that the conversion changed
- Tested a converted hostname on the new gateway before DNS moved, and gated conversions in CI

In the next step `018` we will upgrade both clusters from Istio 1.28 to 1.29 under load, and roll back
