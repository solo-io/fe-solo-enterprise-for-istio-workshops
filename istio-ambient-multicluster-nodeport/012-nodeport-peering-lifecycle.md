# Keep NodePort Peering Healthy as Clusters Change

# Objectives
- Detect drift between each remote-peer Gateway and the peer cluster it describes
- Break peering by recreating an east-west Service, and see why the failure appears later
- Repair the peering, then pin the NodePorts so a recreated Service keeps them
- Take a cluster out of the mesh and bring it back with a loop that works for any number of clusters

## Prerequisites
- This lab assumes you have completed setup from labs `000-011`
- The monitoring stack from lab `010` is running. This lab uses the cluster2 Prometheus agent as a cross-cluster client

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER2=cluster2    # Recommended to keep as cluster2 for POC
```

Lab `006` points the peers at the control-plane nodes with `PEER_NODE_SELECTOR`. Set it again in this shell, so the repair steps below use the same nodes. If you unset it in lab `006`, skip the `export` line:
```bash
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
echo "PEER_NODE_SELECTOR=${PEER_NODE_SELECTOR:-<unset: peers use the nodes that run an istio-eastwest pod>}"
```

## Background

Each `istio-remote-peer-<peer>` Gateway is a copy of facts about the peer cluster, taken when you ran `apply_remote_peer` in lab `006`:

| Field in the remote-peer Gateway | Copied from the peer cluster | Changes when |
|---|---|---|
| `spec.addresses` | Node InternalIPs | A listed node is replaced, renumbered or removed |
| `cross-network` listener port | The HBONE NodePort of `svc/istio-eastwest` | The Service is deleted and recreated, for example by a reinstall or a cleanup script |
| `xds-tls` listener port | The xDS NodePort of `svc/istio-eastwest` | Same as above |

Nothing updates the copy when the peer changes. This lab builds the routine that keeps it current: a drift check, a repair, and NodePort pinning that removes one cause of drift.

## Check for Drift

The function below compares one remote-peer Gateway with the live state of its peer. It checks that the listener ports equal the peer's NodePorts, and that every address is still a node in the peer cluster. It prints `OK` or one `DRIFT` line per problem, and returns a non-zero code on drift, so you can run it from a scheduled job and alert on failure:
```bash
check_peer_drift() {
  local LOCAL_CTX=$1 PEER_CTX=$2 PEER_MESH=$3 GW WANT_HBONE WANT_XDS HAVE_HBONE HAVE_XDS PEER_NODE_IPS ADDR STATUS=OK
  GW=istio-remote-peer-$PEER_MESH
  WANT_HBONE=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  WANT_XDS=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  HAVE_HBONE=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.listeners[?(@.name=="cross-network")].port}')
  HAVE_XDS=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.listeners[?(@.name=="xds-tls")].port}')
  PEER_NODE_IPS=" $(kubectl get nodes --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address} {end}')"
  if [ "$WANT_HBONE" != "$HAVE_HBONE" ] || [ "$WANT_XDS" != "$HAVE_XDS" ]; then
    echo "DRIFT  $LOCAL_CTX/$GW: listener ports $HAVE_HBONE/$HAVE_XDS, $PEER_CTX NodePorts are $WANT_HBONE/$WANT_XDS"
    STATUS=DRIFT
  fi
  for ADDR in $(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.addresses[*].value}'); do
    case "$PEER_NODE_IPS" in
      *" $ADDR "*) ;;
      *) echo "DRIFT  $LOCAL_CTX/$GW: address $ADDR is not a node in $PEER_CTX"; STATUS=DRIFT ;;
    esac
  done
  [ $STATUS = OK ] && echo "OK     $LOCAL_CTX/$GW: $(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.addresses[*].value}') ports $HAVE_HBONE/$HAVE_XDS"
  [ $STATUS = OK ]
}

check_peer_drift $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output (addresses and ports differ on your machine):
```
OK     cluster1/istio-remote-peer-cluster2: 172.30.0.4 ports 31213/32512
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2 ports 31892/30897
```

Define a probe for the cluster2 to cluster1 direction. The cluster2 Prometheus agent calls the central Prometheus in cluster1 through its global hostname, and `prometheus-auth` from lab `010` allows it:
```bash
probe_cluster2_to_cluster1() {
  kubectl exec deploy/prometheus -n monitoring --context $KUBECONTEXT_CLUSTER2 -- \
    wget -qO- -T 5 http://prometheus.monitoring.mesh.internal:9090/-/ready 2>&1 | grep -v "command terminated"
}
probe_cluster2_to_cluster1
```

Expected output:
```
Prometheus Server is Ready.
```

## Break the Peering

Delete the east-west Service in cluster1. Istio recreates it right away, because the `istio-eastwest` Gateway still exists, but Kubernetes assigns new random NodePorts:
```bash
kubectl delete svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
sleep 5
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output:
```
service "istio-eastwest" deleted from istio-gateways namespace
NAME             TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)                                           AGE
istio-eastwest   NodePort   10.110.54.75   <none>        15021:31626/TCP,15008:31958/TCP,15012:32508/TCP   5s
DRIFT  cluster2/istio-remote-peer-cluster1: listener ports 31892/30897, cluster1 NodePorts are 31958/32508
```

cluster2 still sends HBONE and xDS traffic to the old NodePorts. Probe the path:
```bash
probe_cluster2_to_cluster1
```

Expected output:
```
Prometheus Server is Ready.
```

The probe still works. ztunnel and istiod keep long-lived connections to the peer, and connections that were open before the change keep working through kube-proxy's connection tracking. Nothing fails until those connections are re-established. Force that now by restarting the ztunnel on the agent's node and cluster2's istiod:
```bash
AGENT_NODE=$(kubectl get pod -n monitoring -l app=prometheus --context $KUBECONTEXT_CLUSTER2 -o jsonpath='{.items[0].spec.nodeName}')
kubectl delete pod -n istio-system -l app=ztunnel --field-selector spec.nodeName=$AGENT_NODE --context $KUBECONTEXT_CLUSTER2
kubectl rollout status ds/ztunnel -n istio-system --watch --timeout=90s --context $KUBECONTEXT_CLUSTER2
kubectl rollout restart deploy/istiod -n istio-system --context $KUBECONTEXT_CLUSTER2
kubectl rollout status deploy/istiod -n istio-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER2
sleep 10
probe_cluster2_to_cluster1
```

Expected output:
```
wget: error getting response: Connection reset by peer
```

The new istiod in cluster2 now dials cluster1 on the old xDS NodePort. Wait until the old istiod pod is gone and the peering check reports the disconnect, for up to 90 seconds:
```bash
for i in $(seq 1 18); do
  ./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2" 2>&1 | grep -q "Disconnected from" && break
  sleep 5
done
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2" 2>&1 | grep -A1 "Peers Check"
kubectl logs deploy/istiod -n istio-system --context $KUBECONTEXT_CLUSTER2 --since=2m | grep "target=peering" | grep "connection refused" | tail -1
```

Expected output:
```
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
⚠  Peers Check: found disconnected cluster(s)
     ⚠  Disconnected from cluster1 (address: 172.30.0.2)
2026-10-12T23:58:54.380394Z	warn	deltaadsc	disconnected, retrying in 975.046852ms: delta stream: rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp 172.30.0.2:30897: connect: connection refused"	target=peering-cluster1
```

Both planes fail in the cluster2 to cluster1 direction. The data plane resets the agent's request, and istiod in cluster2 cannot reconnect to cluster1 on the old xDS NodePort `30897`. cluster1 to cluster2 still works, because nothing changed in cluster2.

> **Drift is silent until connections reset.** A ztunnel restart, an istiod rollout, a node reboot or an idle timeout can turn hours-old drift into an outage. Run the drift check on a schedule, so you find the drift before a routine restart does.

## Repair the Peering

The fix is the `apply_remote_peer` function from lab `006`, run for the direction that drifted. The function is repeated here so this lab works in a new shell:
```bash
apply_remote_peer() {
  local LOCAL_CTX=$1 PEER_CTX=$2 PEER_MESH=$3 HBONE_PORT XDS_PORT PEER_IPS PEER_ADDRESSES
  HBONE_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX \
    -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  XDS_PORT=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX \
    -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  if [ -n "$PEER_NODE_SELECTOR" ]; then
    PEER_IPS=$(kubectl get nodes -l "$PEER_NODE_SELECTOR" --context $PEER_CTX \
      -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
  else
    PEER_IPS=$(kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest \
      --field-selector=status.phase=Running \
      --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.hostIP} {.metadata.deletionTimestamp}{"\n"}{end}' \
      | awk 'NF == 1 { print $1 }')
  fi
  PEER_ADDRESSES=$(printf '%s\n' "$PEER_IPS" | sort -u \
    | awk 'NF { printf "  - type: IPAddress\n    value: %s\n", $1 }')
  if [ -z "$HBONE_PORT" ] || [ -z "$XDS_PORT" ] || [ -z "$PEER_ADDRESSES" ]; then
    echo "No istio-eastwest NodePorts or peer node addresses found in $PEER_CTX. Finish the steps above in $PEER_CTX first."
    return 1
  fi
  echo "istio-remote-peer-$PEER_MESH in $LOCAL_CTX: HBONE $HBONE_PORT, xDS $XDS_PORT"
  kubectl apply --context $LOCAL_CTX -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-remote-peer-$PEER_MESH
  namespace: istio-gateways
  annotations:
    gateway.istio.io/service-account: istio-eastwest
    gateway.istio.io/trust-domain: $PEER_MESH.local
  labels:
    topology.istio.io/cluster: $PEER_MESH
    topology.istio.io/network: $PEER_MESH
spec:
  gatewayClassName: istio-remote
  addresses:
$PEER_ADDRESSES
  listeners:
  - name: cross-network
    port: $HBONE_PORT
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: $XDS_PORT
    protocol: TLS
    tls:
      mode: Passthrough
EOF
}

apply_remote_peer $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
until probe_cluster2_to_cluster1 | grep -q Ready; do sleep 3; done
probe_cluster2_to_cluster1
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2" 2>&1 | grep -A1 "Peers Check"
```

Expected output:
```
istio-remote-peer-cluster1 in cluster2: HBONE 31958, xDS 32508
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster1 configured
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2 ports 31958/32508
Prometheus Server is Ready.
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
✅ Peers Check: all clusters connected
     ✅ Connected to cluster1 via 172.30.0.2
```

Both planes recover as soon as cluster2 has the new ports.

## Pin the NodePorts

A recreated Service gets random NodePorts unless the Service asks for specific ones. Istio builds the `istio-eastwest` Service from the Gateway, and a ConfigMap referenced in `spec.infrastructure.parametersRef` can overlay the Service spec, including fixed NodePorts. The function below pins the ports that each cluster uses today, so no peer needs an update:
```bash
pin_eastwest_nodeports() {
  local CTX=$1 STATUS HBONE XDS
  STATUS=$(kubectl get svc istio-eastwest -n istio-gateways --context $CTX -o jsonpath='{.spec.ports[?(@.port==15021)].nodePort}')
  HBONE=$(kubectl get svc istio-eastwest -n istio-gateways --context $CTX -o jsonpath='{.spec.ports[?(@.port==15008)].nodePort}')
  XDS=$(kubectl get svc istio-eastwest -n istio-gateways --context $CTX -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  kubectl apply --context $CTX -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-eastwest-options
  namespace: istio-gateways
data:
  service: |
    spec:
      ports:
      # Keep Istio's port names: Istio reads the protocol from the tls- prefix
      - name: status-port
        port: 15021
        nodePort: $STATUS
      - name: tls-hbone
        port: 15008
        nodePort: $HBONE
      - name: tls-xds
        port: 15012
        nodePort: $XDS
EOF
  kubectl patch gateway istio-eastwest -n istio-gateways --context $CTX --type=merge \
    -p '{"spec":{"infrastructure":{"parametersRef":{"group":"","kind":"ConfigMap","name":"istio-eastwest-options"}}}}'
}

for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  pin_eastwest_nodeports $context
done
```

Delete the cluster1 Service again. This time it comes back with the same NodePorts, and the peer in cluster2 stays correct:
```bash
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
kubectl delete svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
sleep 5
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output:
```
31626 31958 32508
service "istio-eastwest" deleted from istio-gateways namespace
31626 31958 32508
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2 ports 31958/32508
```

> **Choose the NodePorts per site in production.** Pick fixed values for HBONE and xDS, write them into the ConfigMap in the install pipeline before the first peering, and open exactly those two ports in firewalls and security groups. Every cluster can use the same two numbers, because each cluster's NodePort range is separate. A pinned port fails to apply if another Service in the cluster already holds it, so reserve the two values for the east-west gateway.

Pinning removes port drift. Address drift remains: a listed node can still be replaced. The control-plane default from lab `006` lowers how often that happens, and the drift check reports it when it does.

## Take a Cluster Out and Bring It Back

Rebuilding, decommissioning or isolating a cluster starts with unpeering it. First move traffic off it, the same way lab `011` moved a hostname. Then delete the remote-peer Gateways on both sides. Check the global services in cluster1 before and after:
```bash
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
kubectl delete gateway istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --context $KUBECONTEXT_CLUSTER1
kubectl delete gateway istio-remote-peer-$MESH_NAME_CLUSTER1 -n istio-gateways --context $KUBECONTEXT_CLUSTER2
sleep 10
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
kubectl get serviceentry -n istio-system --context $KUBECONTEXT_CLUSTER2
probe_cluster2_to_cluster1
```

Expected output:
```
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     2/2
monitoring         autogen.monitoring.prometheus          240.240.0.7,2001:2::7 None     1/1
gateway.gateway.networking.k8s.io "istio-remote-peer-cluster2" deleted from istio-gateways namespace
gateway.gateway.networking.k8s.io "istio-remote-peer-cluster1" deleted from istio-gateways namespace
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     1/1
monitoring         autogen.monitoring.prometheus          240.240.0.7,2001:2::7 None     1/1
NAME                                     HOSTS                                              LOCATION        RESOLUTION   AGE
autogen.bookinfo-frontends.productpage   ["productpage.bookinfo-frontends.mesh.internal"]   MESH_INTERNAL   STATIC       6h40m
wget: bad address 'prometheus.monitoring.mesh.internal:9090'
```

The global productpage in cluster1 dropped from two endpoints to one, so it no longer has a failover target. cluster2 lost `prometheus.monitoring.mesh.internal` completely, because that service runs only in cluster1. Before you unpeer a cluster, list the global services that exist only on one side: their callers on the other side lose them.

Bring the cluster back. The loop below applies a remote-peer Gateway for every ordered pair of clusters. With two clusters it applies two Gateways. Each list entry is `<kubectl context>=<mesh name>`. A new third cluster, installed with labs `002` and `003`, joins by adding one entry: the loop then applies the four new Gateways it needs, and re-applies the existing two with the same values. Lab `018` adds two clusters this way:
```bash
ALL_CLUSTERS=("$KUBECONTEXT_CLUSTER1=$MESH_NAME_CLUSTER1" "$KUBECONTEXT_CLUSTER2=$MESH_NAME_CLUSTER2")
for local in "${ALL_CLUSTERS[@]}"; do
  for peer in "${ALL_CLUSTERS[@]}"; do
    [ "$local" = "$peer" ] && continue
    apply_remote_peer "${local%%=*}" "${peer%%=*}" "${peer#*=}"
  done
done
kubectl wait --for=condition=Programmed gateway/istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --timeout=60s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=Programmed gateway/istio-remote-peer-$MESH_NAME_CLUSTER1 -n istio-gateways --timeout=60s --context $KUBECONTEXT_CLUSTER2
until probe_cluster2_to_cluster1 | grep -q Ready; do sleep 3; done
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
```

Expected output:
```
istio-remote-peer-cluster2 in cluster1: HBONE 31213, xDS 32512
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster2 created
istio-remote-peer-cluster1 in cluster2: HBONE 31958, xDS 32508
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster1 created
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster2 condition met
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster1 condition met
NAMESPACE          SERVICE NAME                           SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends autogen.bookinfo-frontends.productpage 240.240.0.1,2001:2::1 None     2/2
monitoring         autogen.monitoring.prometheus          240.240.0.7,2001:2::7 None     1/1
```

productpage is back to two endpoints, and the agent in cluster2 reaches cluster1 again.

| Lifecycle event | Effect on peering | What to run |
|---|---|---|
| A peer node is replaced or renumbered | Its address goes stale. Peering fails if it was the only address | `check_peer_drift`, then `apply_remote_peer` for each direction that points at it |
| `svc/istio-eastwest` is recreated | New NodePorts, unless pinned | Pin the NodePorts once. Without the pin, `apply_remote_peer` toward that cluster |
| A cluster is rebuilt with the same mesh name and root CA | New node IPs and NodePorts | Install with labs `002` and `003`, pin the same NodePorts, then run the all-pairs loop |
| A cluster joins | No peering yet | Add it to `ALL_CLUSTERS`, then run the all-pairs loop |
| A cluster leaves | Its global services disappear for the other clusters | Move traffic off it, then delete its remote-peer Gateways on every side |

> **Upgrades.** An istiod upgrade or a ztunnel rollout re-establishes every peering connection, which is exactly the moment that hidden drift turns into an outage. Run `check_peer_drift` for every pair before you start, as lab `017` does.

## Cleanup

No cleanup is needed. The NodePort pins and the repaired peering stay in place: the pins keep the east-west NodePorts fixed for the rest of the workshop, and lab `019` deletes them with the `istio-gateways` namespace.

## Next Steps
At this point we have completed the following objectives:
- Detected drift between each remote-peer Gateway and the peer cluster it describes
- Broke peering by recreating an east-west Service, and saw why the failure appeared later
- Repaired the peering, then pinned the NodePorts so a recreated Service keeps them
- Took a cluster out of the mesh and brought it back with a loop that works for any number of clusters

In the next step `013` we will serve per-hostname certificates from cert-manager on the ingress gateway
