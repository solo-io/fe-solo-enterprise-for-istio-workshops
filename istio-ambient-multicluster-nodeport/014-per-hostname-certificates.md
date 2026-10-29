# Let App Teams Own Their Hostnames and Certificates

# Objectives
- Install cert-manager and create a `ClusterIssuer` backed by an internal CA with an ECDSA P-256 key
- Open the shared `ingress` Gateway to listeners from team namespaces
- Let the Bookinfo team serve `bookinfo.example.com` with its own certificate, listener and route, from its own namespace
- Onboard a second team, `shop`, that serves `shop.example.com` the same way
- Verify the certificate that each hostname serves, and that an unknown hostname gets none
- Rotate a team's certificate and confirm the gateway serves the new one without a restart

## Prerequisites
- This lab assumes you have completed setup from labs `000-013`
- `INGRESS_ADDR` from lab `006` is set. If you use the NodePort or port-forward fallback from lab `006`, set `INGRESS_TLS_PORT` below to the `443` NodePort, or set it to `8443` and forward `8443:443` once the first HTTPS listener exists

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export CERT_MANAGER_VERSION=v1.21.2
export INGRESS_IP=${INGRESS_ADDR%:*}
[ "$INGRESS_IP" = localhost ] && export INGRESS_IP=127.0.0.1   # curl --resolve needs an IP
export INGRESS_TLS_PORT=443           # The 443 NodePort, or 8443 with a port-forward
echo "INGRESS_IP=$INGRESS_IP INGRESS_TLS_PORT=$INGRESS_TLS_PORT"
```

## Background

A wildcard certificate covers every hostname under a domain with one key. If that key leaks, every hostname is exposed, and every team that serves one of those hostnames shares the same renewal. A certificate per hostname limits each key to one hostname.

If every HTTPS listener lives on the shared `Gateway`, the platform team edits that Gateway for each new hostname and each certificate change. A listener set moves the listener, and the certificate it names, into the team's namespace. The team attaches its own HTTPS listener to the shared Gateway and never edits the Gateway.

Gateway API added `ListenerSet` in v1.5. Lab `002` installs Gateway API v1.4.1, which has no `ListenerSet`. Solo Enterprise for agentgateway ships `EnterpriseListenerSet` (`enterprise.solo.io/v1alpha1`, short name `elset`) with the same shape: a `parentRef` to a Gateway, and a list of listeners.

The platform team and each app team own different objects:

| Owner | Object | Role |
|---|---|---|
| Platform | `ClusterIssuer` `internal-pki` | Signs every team's certificates. In this lab it is a CA issuer with a self-signed ECDSA P-256 root. In production, point it at your internal PKI instead (for example a Vault, Venafi or ACME issuer) |
| Platform | `ingress` Gateway, annotation `enterprise.solo.io/allowedListeners` | Accepts listener sets only from namespaces with the label `ingress.example.com/listeners=allowed`. The Gateway rejects every listener set by default |
| Platform | Namespace label `ingress.example.com/listeners=allowed` | Onboards a team namespace |
| App team | `Certificate` and its Secret | One ECDSA P-256 certificate per hostname, in the team's namespace |
| App team | `EnterpriseListenerSet` | The HTTPS listener for the team's hostname, naming the team's Secret |
| App team | `HTTPRoute` | Routes the team's hostname, attached to its listener set |

The agentgateway controller watches the Secrets that each listener names and pushes a renewed certificate to the gateway pods over its configuration stream. The running pods serve the new certificate.

## Install cert-manager

Install cert-manager with its CRDs:
```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager --create-namespace \
  --version $CERT_MANAGER_VERSION \
  --set crds.enabled=true
kubectl rollout status deploy -n cert-manager --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
deployment "cert-manager" successfully rolled out
deployment "cert-manager-cainjector" successfully rolled out
deployment "cert-manager-webhook" successfully rolled out
```

## Create the Internal CA Issuer

Create a self-signed bootstrap issuer, an ECDSA P-256 root CA signed by it, and the `internal-pki` CA issuer that signs with that root:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: workshop-internal-root-ca
  secretName: internal-root-ca
  duration: 87600h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-pki
spec:
  ca:
    secretName: internal-root-ca
EOF
kubectl wait --for=condition=Ready certificate/internal-root-ca -n cert-manager --timeout=60s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Ready clusterissuer/internal-pki --timeout=60s --context $KUBECONTEXT_CLUSTER1
```

Save the root certificate to a local file, so clients can verify what the gateway serves:
```bash
kubectl get secret internal-root-ca -n cert-manager --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > internal-root-ca.pem
openssl x509 -in internal-root-ca.pem -noout -subject
```

Expected output:
```
subject=CN=workshop-internal-root-ca
```

## Open the Gateway to Team Listeners

As the platform team, re-apply the `ingress` Gateway from lab `005` with the `enterprise.solo.io/allowedListeners` annotation. The annotation holds the Gateway API `allowedListeners` structure as JSON, because Gateway API v1.4.1 has no `spec.allowedListeners` field. The `http` listener stays as it was:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: agentgateway-system
  annotations:
    enterprise.solo.io/allowedListeners: '{"namespaces":{"from":"Selector","selector":{"matchLabels":{"ingress.example.com/listeners":"allowed"}}}}'
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: ingress-config
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

Onboard the Bookinfo team by allowing its namespace to attach listeners:
```bash
kubectl label namespace bookinfo-frontends ingress.example.com/listeners=allowed --context $KUBECONTEXT_CLUSTER1
```

## Serve bookinfo.example.com from the Team Namespace

As the Bookinfo team, request an ECDSA P-256 certificate for `bookinfo.example.com` in `bookinfo-frontends`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: bookinfo-example-com
  namespace: bookinfo-frontends
spec:
  secretName: bookinfo-example-com-tls
  dnsNames:
  - bookinfo.example.com
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: internal-pki
    kind: ClusterIssuer
EOF
kubectl wait --for=condition=Ready certificate/bookinfo-example-com -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
certificate.cert-manager.io/bookinfo-example-com created
certificate.cert-manager.io/bookinfo-example-com condition met
```

Attach an HTTPS listener for `bookinfo.example.com` to the `ingress` Gateway, and route it to the global productpage hostname from lab `007`. The route's `parentRef` names the listener set and its `https` listener:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: enterprise.solo.io/v1alpha1
kind: EnterpriseListenerSet
metadata:
  name: bookinfo
  namespace: bookinfo-frontends
spec:
  parentRef:
    name: ingress
    namespace: agentgateway-system
  listeners:
  - name: https
    hostname: bookinfo.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: bookinfo-example-com-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-https-route
  namespace: bookinfo-frontends
spec:
  parentRefs:
  - group: enterprise.solo.io
    kind: EnterpriseListenerSet
    name: bookinfo
    sectionName: https
  hostnames:
  - bookinfo.example.com
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
sleep 5
kubectl get httproute bookinfo-https-route -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl get svc ingress -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .spec.ports[*]}{.port}:{.nodePort} {end}{"\n"}'
```

Expected output:
```
enterpriselistenerset.enterprise.solo.io/bookinfo created
httproute.gateway.networking.k8s.io/bookinfo-https-route created
Accepted=True
ResolvedRefs=True
80:31519 443:30819
```

The route is accepted by the listener set, and the controller added port `443` to the gateway Service, because no Gateway listener used that port before.

> **Listener set status on 2026.9.x.** `kubectl get elset` shows `Unknown` for `ACCEPTED` and `PROGRAMMED` on agentgateway 2026.9.x, because that release does not write listener set status. Use the route status and the traffic checks in this lab instead. agentgateway 2026.10.0 fixes listener set status.

## Onboard a Second Team

The `shop` team deploys its app in a new ambient namespace, and requests its own certificate for `shop.example.com`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: shop
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
        args: ["--port", "8080", "--cluster", "cluster1"]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: shop
spec:
  selector:
    app: echo
  ports:
  - name: http
    port: 8080
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shop-example-com
  namespace: shop
spec:
  secretName: shop-example-com-tls
  dnsNames:
  - shop.example.com
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: internal-pki
    kind: ClusterIssuer
EOF
kubectl rollout status deploy/echo -n shop --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Ready certificate/shop-example-com -n shop --timeout=60s --context $KUBECONTEXT_CLUSTER1
```

As the platform team, onboard `shop`:
```bash
kubectl label namespace shop ingress.example.com/listeners=allowed --context $KUBECONTEXT_CLUSTER1
```

As the `shop` team, attach an HTTPS listener for `shop.example.com`, and route it to `echo`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: enterprise.solo.io/v1alpha1
kind: EnterpriseListenerSet
metadata:
  name: shop
  namespace: shop
spec:
  parentRef:
    name: ingress
    namespace: agentgateway-system
  listeners:
  - name: https
    hostname: shop.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: shop-example-com-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-https-route
  namespace: shop
spec:
  parentRefs:
  - group: enterprise.solo.io
    kind: EnterpriseListenerSet
    name: shop
    sectionName: https
  hostnames:
  - shop.example.com
  rules:
  - backendRefs:
    - name: echo
      port: 8080
EOF
sleep 5
kubectl get httproute shop-https-route -n shop --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
```

Expected output:
```
enterpriselistenerset.enterprise.solo.io/shop created
httproute.gateway.networking.k8s.io/shop-https-route created
Accepted=True
ResolvedRefs=True
```

## Verify Each Hostname

> **Port-forward users:** start the HTTPS forward now, in another terminal: `kubectl port-forward svc/ingress -n agentgateway-system 8443:443 --context $KUBECONTEXT_CLUSTER1`

Show the certificate that each hostname gets. `-servername` sets the TLS SNI, which the gateway uses to pick the listener:
```bash
for HOST in bookinfo.example.com shop.example.com; do
  echo "== $HOST"
  openssl s_client -connect $INGRESS_IP:$INGRESS_TLS_PORT -servername $HOST -CAfile internal-root-ca.pem </dev/null 2>/dev/null \
    | grep -E "Peer signature type|Server public key|Verify return code"
  openssl s_client -connect $INGRESS_IP:$INGRESS_TLS_PORT -servername $HOST </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -ext subjectAltName
  curl -s --cacert internal-root-ca.pem --resolve $HOST:$INGRESS_TLS_PORT:$INGRESS_IP \
    -o /dev/null -w "curl https://$HOST/productpage -> %{http_code}\n" https://$HOST:$INGRESS_TLS_PORT/productpage
done
```

Expected output:
```
== bookinfo.example.com
Peer signature type: ecdsa_secp256r1_sha256
Server public key is 256 bit
Verify return code: 0 (ok)
issuer=CN=workshop-internal-root-ca
X509v3 Subject Alternative Name: critical
    DNS:bookinfo.example.com
curl https://bookinfo.example.com/productpage -> 200
== shop.example.com
Peer signature type: ecdsa_secp256r1_sha256
Server public key is 256 bit
Verify return code: 0 (ok)
issuer=CN=workshop-internal-root-ca
X509v3 Subject Alternative Name: critical
    DNS:shop.example.com
curl https://shop.example.com/productpage -> 200
```

Each hostname has its own ECDSA P-256 certificate with its own hostname as the only SAN, and `curl` verified both chains against the internal root. The `shop` request reached `echo`, which answers on every path.

Request a hostname that has no listener:
```bash
curl -s --cacert internal-root-ca.pem --resolve other.example.com:$INGRESS_TLS_PORT:$INGRESS_IP \
  -o /dev/null -w "%{http_code} %{errormsg}\n" https://other.example.com:$INGRESS_TLS_PORT/productpage
```

Expected output (the exact error text depends on your curl build):
```
000 TLS connect error: error:0A000126:SSL routines::unexpected eof while reading
```

The gateway closes the handshake, because no listener matches the SNI. It has no default certificate to fall back to, so a mistyped or retired hostname cannot pick up another hostname's certificate.

## Rotate a Certificate

Record the serial number and the gateway pod's restart count, then delete the Bookinfo team's Secret to force cert-manager to issue a new certificate:
```bash
serial() {
  openssl s_client -connect $INGRESS_IP:$INGRESS_TLS_PORT -servername $1 -CAfile internal-root-ca.pem </dev/null 2>/dev/null \
    | openssl x509 -noout -serial
}
gateway_restarts() {
  kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=ingress --context $KUBECONTEXT_CLUSTER1 \
    -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}{"\n"}'
}
OLD_SERIAL=$(serial bookinfo.example.com)
echo "$OLD_SERIAL"
gateway_restarts
kubectl delete secret bookinfo-example-com-tls -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Ready certificate/bookinfo-example-com -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
for i in $(seq 1 30); do
  [ "$(serial bookinfo.example.com)" != "$OLD_SERIAL" ] && break
  sleep 1
done
serial bookinfo.example.com
gateway_restarts
```

Expected output:
```
serial=44F1D6EB56FE8B7984BCC460C2E4C384B67EFC1C
ingress-55cd48866f-8bgcj restarts=0
secret "bookinfo-example-com-tls" deleted from bookinfo-frontends namespace
certificate.cert-manager.io/bookinfo-example-com condition met
serial=06038DF7BBA5D3FFD412F5E3A4002BD543411E5C
ingress-55cd48866f-8bgcj restarts=0
```

The gateway serves the new serial from the same pod, with no restart. Scheduled renewals take the same path: by default cert-manager renews a certificate when two thirds of its 90-day lifetime has passed.

> **Ingress in more than one cluster.** Each cluster's gateway needs its own copy of each Secret. Install cert-manager in every cluster that runs an ingress gateway, point each cluster's `internal-pki` issuer at the same internal CA, and apply the same Gateway annotation and namespace labels. Each team then applies the same `Certificate`, listener set and route in every cluster.

> **Moving to Gateway API `ListenerSet`.** Once your clusters run Gateway API v1.5 or later, the platform team moves the gate from the annotation to the Gateway's `spec.allowedListeners` field, and each team changes `apiVersion: enterprise.solo.io/v1alpha1`, `kind: EnterpriseListenerSet` to `apiVersion: gateway.networking.k8s.io/v1`, `kind: ListenerSet`, and the route's `parentRef` to match.

## Cleanup

Remove the teams' listener sets, routes and certificates, and the `shop` namespace:
```bash
kubectl delete httproute bookinfo-https-route -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete elset bookinfo -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete certificate bookinfo-example-com -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete secret bookinfo-example-com-tls -n bookinfo-frontends --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl label namespace bookinfo-frontends ingress.example.com/listeners- --context $KUBECONTEXT_CLUSTER1
kubectl delete namespace shop --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

Put the `ingress` Gateway back to the version from lab `005`, and remove the issuers and the root:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: ingress-config
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
kubectl delete clusterissuer internal-pki selfsigned-bootstrap --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete certificate internal-root-ca -n cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete secret internal-root-ca -n cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
rm -f internal-root-ca.pem
```

Uninstall cert-manager. The CRDs stay, because removing a CRD deletes every resource of that kind. Lab `021` removes them:
```bash
helm uninstall cert-manager -n cert-manager --kube-context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

## Next Steps
At this point we have completed the following objectives:
- Installed cert-manager and created a `ClusterIssuer` backed by an internal CA with an ECDSA P-256 key
- Opened the shared `ingress` Gateway to listeners from team namespaces
- Let the Bookinfo team serve `bookinfo.example.com` with its own certificate, listener and route, from its own namespace
- Onboarded the `shop` team, which serves `shop.example.com` the same way
- Verified the certificate that each hostname serves, and that an unknown hostname gets none
- Rotated a team's certificate and confirmed the gateway served the new one without a restart

In the next step `015` we will carry the real client IP through the ingress gateway and across clusters
