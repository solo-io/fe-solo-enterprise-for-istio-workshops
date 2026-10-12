# Kubernetes Ambient Multicluster NodePort Workshop

# Objectives
- Deploy Istio on Kubernetes with Helm based install
- Deploy sample microservices on two different namespaces (bookinfo app)
- Install Istio Ambient Mesh
- Enable Ambient Mesh for app namespaces (bookinfo-frontends and bookinfo-backends)
- Setup Ingress Gateway to access the bookinfo frontend (productpage)
- Peer the two clusters through NodePort east-west gateways, with no LoadBalancer
- Configure a globally available service using labels (productpage)
- Reconfigure ingress to global service hostname (*.<namespace>.mesh.internal)

# Use Cases
- Zero Trust (mTLS)
- Ingress
- Multi-cluster routing
- Global service discovery
- High Availability
- Failover

## NodePort Peering

This workshop follows Solo's multi-cluster NodePort reference architecture ([`solo-reference-architectures/Ambient_Mesh/multi-cluster-nodeport`](https://github.com/solo-io/solo-reference-architectures/tree/main/Ambient_Mesh/multi-cluster-nodeport), Solo access required). Each cluster exposes its east-west gateway as a `NodePort` Service. Each cluster's remote-peer Gateway points at the other cluster's node InternalIPs and at the NodePorts for HBONE (`15008`) and xDS (`15012`). The design fits on-premises and private networks where the nodes of both clusters reach each other directly.

## Validated on
- Kubernetes ≥ 1.29
- Istio 1.28.10-patch0-solo
- vind on Docker Desktop (arm64): two clusters with two nodes each, peered over NodePorts

# High Level Architecture Diagram
![](../images/multicluster-global-mesh-2.png)

## License Key Details
This workshop requires a Solo Trial License Key, exported as `SOLO_TRIAL_LICENSE_KEY` in lab `002`.
Contact your Solo.io account team if you need one. Check the expiry before you start:

```bash
for SEG in $(echo "$SOLO_TRIAL_LICENSE_KEY" | tr '.' ' '); do
  case $(( ${#SEG} % 4 )) in 2) SEG="${SEG}==" ;; 3) SEG="${SEG}=" ;; esac
  EXP=$(printf '%s' "$SEG" | tr '_-' '/+' | base64 -d 2>/dev/null \
        | LC_ALL=C sed -n 's/.*"exp":\([0-9]*\).*/\1/p')
  [ -n "$EXP" ] && break
done

if [ -z "$EXP" ]; then
  echo "Could not read an expiry from SOLO_TRIAL_LICENSE_KEY. Is it set?"
else
  date -d "@$EXP" 2>/dev/null || date -r "$EXP"
fi
```
