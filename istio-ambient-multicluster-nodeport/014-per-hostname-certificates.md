# Serve Per-Hostname Certificates from cert-manager

# Objectives
- Install cert-manager with Gateway API support
- Create a `ClusterIssuer` backed by an internal CA with an ECDSA P-256 key
- Give each ingress hostname its own ECDSA P-256 certificate, issued from annotations on the `Gateway`
- Verify the certificate that each hostname serves, and that an unknown hostname gets none
- Rotate a certificate and confirm the gateway serves the new one without a restart

## Prerequisites
- This lab assumes you have completed setup from labs `000-013`
- The ingress gateway address from lab `006` serves port `443`. With a LoadBalancer Service that is automatic. With the NodePort or port-forward fallback, use the `443` NodePort or forward `8443:443` and replace `$INGRESS_IP:443` below

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export CERT_MANAGER_VERSION=v1.21.2
export INGRESS_IP=${INGRESS_ADDR%:*}
echo "INGRESS_IP=$INGRESS_IP"
```

## Background

A wildcard certificate covers every hostname under a domain with one key. If that key leaks, every hostname is exposed, and every team that serves one of those hostnames shares the same renewal. A certificate per hostname limits each key to one hostname, and cert-manager makes the extra certificates cheap to run.

agentgateway reads TLS certificates from Kubernetes Secrets named in each listener's `certificateRefs`, in the Gateway's namespace. cert-manager's Gateway API support fills those Secrets:

| Resource | Role |
|---|---|
| `ClusterIssuer` `internal-pki` | Signs certificates. In this lab it is a CA issuer with a self-signed ECDSA P-256 root. In production, point it at your internal PKI instead (for example a Vault, Venafi or ACME issuer) |
| Annotations on the `Gateway` | `cert-manager.io/cluster-issuer` names the issuer. `cert-manager.io/private-key-algorithm` and `cert-manager.io/private-key-size` set ECDSA P-256 for every certificate cert-manager creates for this Gateway |
| One HTTPS listener per hostname | cert-manager creates one `Certificate` per listener, with that listener's `hostname` as the only SAN, stored in the Secret that `certificateRefs` names |

The agentgateway controller watches those Secrets and pushes a renewed certificate to the gateway pods over its configuration stream, and the running pods serve it.

## Install cert-manager

Install cert-manager with its CRDs, and turn on its Gateway API support in the controller configuration:
```bash
helm upgrade --kube-context $KUBECONTEXT_CLUSTER1 --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager --create-namespace \
  --version $CERT_MANAGER_VERSION \
  -f -<<EOF
crds:
  enabled: true
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  # Create Certificates for Gateway listeners from the Gateway's annotations
  gatewayAPI:
    enabled: true
EOF
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

## Add a Listener per Hostname

Re-apply the `ingress` Gateway from lab `005` with the cert-manager annotations and two HTTPS listeners, one for `bookinfo.example.com` and one for `shop.example.com`. The `http` listener stays as it was:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: agentgateway-system
  annotations:
    cert-manager.io/cluster-issuer: internal-pki
    cert-manager.io/private-key-algorithm: ECDSA
    cert-manager.io/private-key-size: "256"
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
  - name: https-bookinfo
    hostname: bookinfo.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: bookinfo-example-com-tls
    allowedRoutes:
      namespaces:
        from: All
  - name: https-shop
    hostname: shop.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: shop-example-com-tls
    allowedRoutes:
      namespaces:
        from: All
EOF
kubectl wait --for=condition=Ready certificate/bookinfo-example-com-tls certificate/shop-example-com-tls \
  -n agentgateway-system --timeout=90s --context $KUBECONTEXT_CLUSTER1
kubectl get certificate -n agentgateway-system --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/ingress -n agentgateway-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
kubectl get svc ingress -n agentgateway-system --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
certificate.cert-manager.io/bookinfo-example-com-tls condition met
certificate.cert-manager.io/shop-example-com-tls condition met
NAME                       READY   SECRET                     AGE
bookinfo-example-com-tls   True    bookinfo-example-com-tls   0s
shop-example-com-tls       True    shop-example-com-tls       0s
deployment "ingress" successfully rolled out
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)                      AGE
ingress   LoadBalancer   10.111.90.138   172.30.255.254   80:31519/TCP,443:30819/TCP   42m
```

cert-manager created one `Certificate` per HTTPS listener, named after the Secret in `certificateRefs`. The `bookinfo-route` from lab `007` has no `hostnames` and no `sectionName`, so it attaches to every listener, including the two new ones.

## Verify Each Hostname

Show the certificate that each hostname gets. `-servername` sets the TLS SNI, which the gateway uses to pick the listener:
```bash
for HOST in bookinfo.example.com shop.example.com; do
  echo "== $HOST"
  openssl s_client -connect $INGRESS_IP:443 -servername $HOST -CAfile internal-root-ca.pem </dev/null 2>/dev/null \
    | grep -E "Peer signature type|Server public key|Verify return code"
  openssl s_client -connect $INGRESS_IP:443 -servername $HOST </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -ext subjectAltName
  curl -s --cacert internal-root-ca.pem --resolve $HOST:443:$INGRESS_IP \
    -o /dev/null -w "curl https://$HOST/productpage -> %{http_code}\n" https://$HOST/productpage
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

Each hostname has its own certificate with its own hostname as the only SAN. `ecdsa_secp256r1_sha256` is ECDSA on the P-256 curve, and the 256-bit public key confirms the key size. `curl` verified both chains against the internal root.

Request a hostname that has no listener:
```bash
curl -s --cacert internal-root-ca.pem --resolve other.example.com:443:$INGRESS_IP \
  -o /dev/null -w "%{http_code} %{errormsg}\n" https://other.example.com/productpage
```

Expected output (the exact error text depends on your curl build):
```
000 TLS connect error: error:0A000126:SSL routines::unexpected eof while reading
```

The gateway closes the handshake, because no listener matches the SNI. It has no default certificate to fall back to, so a mistyped or retired hostname cannot pick up another hostname's certificate.

> **Keeping a wildcard for system traffic.** If a wildcard stays for system components only, give it its own listener with a wildcard `hostname`, such as `*.sys.example.com`. cert-manager issues a wildcard certificate for that listener, and the per-hostname listeners are unaffected, because the gateway matches the most specific hostname first.

## Rotate a Certificate

Record the serial number and the gateway pod's restart count, then delete the Secret to force cert-manager to issue a new certificate:
```bash
serial() {
  openssl s_client -connect $INGRESS_IP:443 -servername $1 -CAfile internal-root-ca.pem </dev/null 2>/dev/null \
    | openssl x509 -noout -serial
}
gateway_restarts() {
  kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=ingress --context $KUBECONTEXT_CLUSTER1 \
    -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}{"\n"}'
}
serial bookinfo.example.com
gateway_restarts
kubectl delete secret bookinfo-example-com-tls -n agentgateway-system --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Ready certificate/bookinfo-example-com-tls -n agentgateway-system --timeout=60s --context $KUBECONTEXT_CLUSTER1
sleep 5
serial bookinfo.example.com
gateway_restarts
```

Expected output:
```
serial=44F1D6EB56FE8B7984BCC460C2E4C384B67EFC1C
ingress-55cd48866f-8bgcj restarts=0
secret "bookinfo-example-com-tls" deleted from agentgateway-system namespace
certificate.cert-manager.io/bookinfo-example-com-tls condition met
serial=06038DF7BBA5D3FFD412F5E3A4002BD543411E5C
ingress-55cd48866f-8bgcj restarts=0
```

The gateway serves the new serial from the same pod, with no restart. Scheduled renewals take the same path: by default cert-manager renews a certificate when two thirds of its 90-day lifetime has passed.

> **Ingress in more than one cluster.** Each cluster's gateway needs its own copy of each Secret. Install cert-manager in every cluster that runs an ingress gateway, and point each cluster's `internal-pki` issuer at the same internal CA. The Gateway annotations and listeners are then identical in every cluster.

## Cleanup

Put the `ingress` Gateway back to the HTTP listener from lab `005`, and remove the issued certificates, the issuers and the root:
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
kubectl delete certificate bookinfo-example-com-tls shop-example-com-tls -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete secret bookinfo-example-com-tls shop-example-com-tls -n agentgateway-system --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete clusterissuer internal-pki selfsigned-bootstrap --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete certificate internal-root-ca -n cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete secret internal-root-ca -n cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
rm -f internal-root-ca.pem
```

Uninstall cert-manager. The CRDs stay, because removing a CRD deletes every resource of that kind. Lab `020` removes them:
```bash
helm uninstall cert-manager -n cert-manager --kube-context $KUBECONTEXT_CLUSTER1 --ignore-not-found
kubectl delete namespace cert-manager --context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

## Next Steps
At this point we have completed the following objectives:
- Installed cert-manager with Gateway API support
- Created a `ClusterIssuer` backed by an internal CA with an ECDSA P-256 key
- Gave each ingress hostname its own ECDSA P-256 certificate, issued from annotations on the `Gateway`
- Verified the certificate that each hostname serves, and that an unknown hostname gets none
- Rotated a certificate and confirmed the gateway served the new one without a restart

In the next step `015` we will carry the real client IP through the ingress gateway and across clusters
