# Keep NodePort Peering Healthy as Clusters Change

# Objectives
- Watch the peer cluster follow an east-west gateway pod to another node
- Check each remote peer's xDS address and port against the peer cluster
- Lose the xDS link to a peer, see what keeps working and what goes stale, and repair it
- Confirm that the fixed NodePorts survive a recreated east-west Service
- Take a cluster out of the mesh and bring it back with a loop that works for any number of clusters

## Prerequisites
- This lab assumes you have completed setup from labs `000-012`
- The monitoring stack from lab `011` is running. This lab uses the cluster2 Prometheus agent as a cross-cluster client
- The east-west gateway pod in cluster1 can move to a second schedulable node
- Run the commands from the workshop directory, so that `source peering/peering.sh` finds the peering helpers

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER2=cluster2    # Recommended to keep as cluster2 for POC
ALL_CLUSTERS=("$KUBECONTEXT_CLUSTER1=$MESH_NAME_CLUSTER1" "$KUBECONTEXT_CLUSTER2=$MESH_NAME_CLUSTER2")
```

Set the chart version, the NodePorts and the peer node selector from lab `007`. If you changed any of them in lab `007`, use your values:
```bash
export PEERING_CHART_VERSION=1.29.7-patch0
export EW_STATUS_NODEPORT=31521
export EW_HBONE_NODEPORT=31508
export EW_XDS_NODEPORT=31512
export PEER_NODE_SELECTOR=node-role.kubernetes.io/control-plane
```

## Background

Peering in this workshop depends on three facts about each peer cluster. Two of them are copies that you write with the `peering` chart, and istiod keeps the third current:

| Fact | Where it lives | Changes when | What updates it |
|---|---|---|---|
| Peer node address for xDS | `spec.addresses` of `istio-remote-peer-<peer>`, from `apply_remote_peers` in lab `007` | That node is replaced, renumbered or removed | You, by running `apply_remote_peers` again |
| Peer xDS NodePort | `xds-tls` listener port, from `EW_XDS_NODEPORT` | You change the fixed NodePorts | You, in the same way |
| Peer nodes for HBONE: every node that runs a Gateway API gateway pod, including the east-west pod | ztunnel's network gateway for the peer | The east-west pod, or another gateway pod, moves to another node | istiod, from the peer's istiod, over the xDS link |

The third fact needs the xDS link, so the xDS address is the one to watch. This lab builds the routine for it: a drift check, a repair, and an unpeer and re-peer loop.

Define a probe for the cluster2 to cluster1 direction. The cluster2 Prometheus agent calls the central Prometheus in cluster1 through its global hostname, and `prometheus-auth` from lab `011` allows it:
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

## Follow the East-West Gateway to Another Node

ztunnel in cluster2 sends HBONE for cluster1 to the cluster1 nodes that cluster1's istiod lists for its east-west gateway. List them, and the node the east-west pod runs on now:
```bash
peer_gateway_nodes() {
  ./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER2 | grep "autogen.node.$MESH_NAME_CLUSTER1" | awk '{print $3}'
}
EW_NODE=$(kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].spec.nodeName}')
echo "cluster1 east-west pod on $EW_NODE ($(kubectl get node $EW_NODE --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'))"
echo "cluster2 sends HBONE to: $(peer_gateway_nodes | tr '\n' ' ')"
```

Expected output (names and addresses differ on your machine):
```
cluster1 east-west pod on cluster1 (172.30.0.2)
cluster2 sends HBONE to: 172.30.0.2 172.30.0.3
```

The list can hold more nodes than the east-west pod's node. istiod lists every node that runs a Gateway API gateway pod: the east-west gateway, the agentgateway `ingress` pod and the waypoints. kube-proxy on each of those nodes forwards HBONE to the east-west pod, as lab `007` showed for xDS.

Move the east-west pod: cordon its node, restart the gateway, and uncordon the node. Then wait until cluster2 lists the new node, for up to 60 seconds:
```bash
kubectl cordon $EW_NODE --context $KUBECONTEXT_CLUSTER1
kubectl rollout restart deploy/istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/istio-eastwest -n istio-gateways --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl uncordon $EW_NODE --context $KUBECONTEXT_CLUSTER1
NEW_IP=$(kubectl get pods -n istio-gateways -l gateway.networking.k8s.io/gateway-name=istio-eastwest --context $KUBECONTEXT_CLUSTER1 \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].status.hostIP}')
for i in $(seq 1 12); do
  peer_gateway_nodes | grep -qx "$NEW_IP" && break
  sleep 5
done
echo "cluster1 east-west pod on $NEW_IP"
echo "cluster2 sends HBONE to: $(peer_gateway_nodes | tr '\n' ' ')"
probe_cluster2_to_cluster1
```

Expected output (abridged; addresses differ on your machine):
```
node/cluster1 cordoned
deployment.apps/istio-eastwest restarted
deployment "istio-eastwest" successfully rolled out
node/cluster1 uncordoned
cluster1 east-west pod on 172.30.0.3
cluster2 sends HBONE to: 172.30.0.2 172.30.0.3
Prometheus Server is Ready.
```

istiod in cluster2 learned the new node from cluster1 within seconds, and nothing in cluster2 changed by hand. A node leaves the list when cluster1's istiod stops reporting it. In the example output, `172.30.0.2` stays, because it runs the agentgateway `ingress` pod, another Gateway API gateway pod.

> **Only one schedulable node?** The rollout waits with the new pod `Pending`. Uncordon the node with `kubectl uncordon $EW_NODE --context $KUBECONTEXT_CLUSTER1` and skip to the next section.

## Check for Drift

`peering/peering.sh` holds the peering helpers: `apply_remote_peers` from lab `007`, and `check_peer_drift`, which compares one remote-peer Gateway with the live state of its peer. It checks that the `xds-tls` port equals the peer's xDS NodePort, that the address is still a node in the peer cluster, and that `PeerConnected` is `True`. It prints `OK` or one `DRIFT` line per problem, and returns a non-zero code on drift, so you can run it from a scheduled job and alert on failure. Load the file, print the function, and run it for both directions:
```bash
source peering/peering.sh
sed -n '/^check_peer_drift()/,/^}/p' peering/peering.sh

check_peer_drift $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output after the function body (addresses differ on your machine):
```
OK     cluster1/istio-remote-peer-cluster2: 172.30.0.4:31512 connected
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2:31512 connected
```

## Lose the xDS Link

Simulate the replacement of the node that cluster2 uses for cluster1: point the remote peer at `192.0.2.10`, an address from the documentation range that no host answers. The command exports the release values, replaces the address, and upgrades the release with the result:
```bash
helm get values peering-remote -n istio-gateways --kube-context $KUBECONTEXT_CLUSTER2 -o yaml \
  | sed 's/address: .*/address: 192.0.2.10/' \
  | helm upgrade peering-remote oci://us-docker.pkg.dev/soloio-img/istio-helm/peering --version $PEERING_CHART_VERSION-solo \
      -n istio-gateways --kube-context $KUBECONTEXT_CLUSTER2 -f - | grep -E "^STATUS"
for i in $(seq 1 18); do
  check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1 > /dev/null || break
  sleep 5
done
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output:
```
STATUS: deployed
DRIFT  cluster2/istio-remote-peer-cluster1: address 192.0.2.10 is not a node in cluster1
DRIFT  cluster2/istio-remote-peer-cluster1: PeerConnected=False
```

Probe the cluster2 to cluster1 path:
```bash
probe_cluster2_to_cluster1
```

Expected output:
```
Prometheus Server is Ready.
```

The data plane still works. istiod in cluster2 keeps the last configuration it received from cluster1, and ztunnel keeps sending HBONE to the cluster1 east-west node it knows. Changes in cluster1 stop reaching cluster2. Make one: label the `ratings` Service in cluster1 as global, and compare what the two clusters know about it:
```bash
kubectl label service ratings -n bookinfo-backends solo.io/service-scope=global --context $KUBECONTEXT_CLUSTER1
for i in $(seq 1 15); do
  ./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -q 'autogen.bookinfo-backends.ratings' && break
  sleep 2
done
for CTX in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  echo "$CTX: $(./solo-istioctl zc services -n istio-system --context $CTX | grep -c 'autogen.bookinfo-backends.ratings') global ratings service"
done
```

Expected output:
```
cluster1: 1 global ratings service
cluster2: 0 global ratings service
```

cluster2 has no record of the new global service.

> **A lost xDS link is quiet.** Cross-cluster traffic keeps flowing, so nothing alerts until a change on the far side is missing, or the old east-west node disappears. Run the drift check on a schedule. It reports `PeerConnected=False` as soon as istiod gives up the connection.

## Repair the Peering

The fix is `apply_remote_peers` from `peering/peering.sh`, run for the cluster whose peer drifted. It reads the peer's node address again, upgrades the release, and the loop waits up to 90 seconds for the link:
```bash
source peering/peering.sh
apply_remote_peers $KUBECONTEXT_CLUSTER2
for i in $(seq 1 30); do
  check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1 > /dev/null && break
  sleep 3
done
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
for i in $(seq 1 10); do
  ./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER2 | grep -q 'autogen.bookinfo-backends.ratings' && break
  sleep 2
done
echo "$KUBECONTEXT_CLUSTER2: $(./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER2 | grep -c 'autogen.bookinfo-backends.ratings') global ratings service"
```

Expected output (addresses differ on your machine):
```
istio-remote-peer-cluster1 in cluster2: xDS 172.30.0.2:31512
STATUS: deployed
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2:31512 connected
cluster2: 1 global ratings service
```

istiod in cluster2 reconnected within seconds and caught up on what changed in cluster1. Remove the `ratings` label again:
```bash
kubectl label service ratings -n bookinfo-backends solo.io/service-scope- --context $KUBECONTEXT_CLUSTER1
```

## Fixed NodePorts Survive a Recreated Service

Lab `007` fixed the east-west NodePorts through the chart. Delete the cluster1 Service: Istio recreates it right away, because the `istio-eastwest` Gateway still exists, and the new Service gets the same NodePorts:
```bash
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
kubectl delete svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1
for i in $(seq 1 15); do
  kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 > /dev/null 2>&1 && break
  sleep 1
done
kubectl get svc istio-eastwest -n istio-gateways --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
```

Expected output:
```
31521 31508 31512
service "istio-eastwest" deleted from istio-gateways namespace
31521 31508 31512
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2:31512 connected
```

Without fixed NodePorts, Kubernetes assigns new random ports to the recreated Service, and every peer that holds the old xDS port loses the link at its next reconnect.

## Take a Cluster Out and Bring It Back

Rebuilding, decommissioning or isolating a cluster starts with unpeering it. First move traffic off it, the same way lab `012` moved a hostname. Then uninstall the `peering-remote` release on both sides. Check the global services in cluster1 before and after:
```bash
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
helm uninstall peering-remote -n istio-gateways --kube-context $KUBECONTEXT_CLUSTER1
helm uninstall peering-remote -n istio-gateways --kube-context $KUBECONTEXT_CLUSTER2
for i in $(seq 1 15); do
  ./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -q 'istio-eastwest.cluster2' || break
  sleep 2
done
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
kubectl get serviceentry -n istio-system --context $KUBECONTEXT_CLUSTER2 -o custom-columns=NAME:.metadata.name --no-headers
probe_cluster2_to_cluster1
```

Expected output:
```
NAMESPACE           SERVICE NAME                             SERVICE VIP             WAYPOINT ENDPOINTS
bookinfo-frontends  autogen.bookinfo-frontends.productpage   240.240.0.2,2001:2::2   None     2/2
istio-gateways      autogen.peering.istio-eastwest.cluster2  240.240.0.16,2001:2::10 None     1/1
monitoring          autogen.monitoring.prometheus            240.240.0.5,2001:2::5   None     1/1
release "peering-remote" uninstalled
release "peering-remote" uninstalled
NAMESPACE           SERVICE NAME                             SERVICE VIP           WAYPOINT ENDPOINTS
bookinfo-frontends  autogen.bookinfo-frontends.productpage   240.240.0.2,2001:2::2 None     1/1
monitoring          autogen.monitoring.prometheus            240.240.0.5,2001:2::5 None     1/1
autogen.bookinfo-frontends.productpage
wget: bad address 'prometheus.monitoring.mesh.internal:9090'
```

The global productpage in cluster1 dropped from two endpoints to one, so it no longer has a failover target, and the `autogen.peering.istio-eastwest.cluster2` entry for the cluster2 east-west nodes is gone. cluster2 lost `prometheus.monitoring.mesh.internal` completely, because that service runs only in cluster1. Before you unpeer a cluster, list the global services that exist only on one side: their callers on the other side lose them.

Bring the cluster back. The loop below runs `apply_remote_peers` in every cluster of `ALL_CLUSTERS`, so each cluster gets one remote peer for every other cluster. Lab `019` adds two clusters with the same loop:
```bash
for entry in "${ALL_CLUSTERS[@]}"; do
  apply_remote_peers "${entry%%=*}"
done
kubectl wait --for=condition=gloo.solo.io/PeerConnected gateway/istio-remote-peer-$MESH_NAME_CLUSTER2 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=condition=gloo.solo.io/PeerConnected gateway/istio-remote-peer-$MESH_NAME_CLUSTER1 -n istio-gateways --timeout=120s --context $KUBECONTEXT_CLUSTER2
for i in $(seq 1 20); do
  probe_cluster2_to_cluster1 | grep -q Ready && break
  sleep 3
done
./solo-istioctl zc services -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|autogen"
```

Expected output (addresses differ on your machine):
```
istio-remote-peer-cluster2 in cluster1: xDS 172.30.0.4:31512
STATUS: deployed
istio-remote-peer-cluster1 in cluster2: xDS 172.30.0.2:31512
STATUS: deployed
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster2 condition met
gateway.gateway.networking.k8s.io/istio-remote-peer-cluster1 condition met
NAMESPACE           SERVICE NAME                             SERVICE VIP             WAYPOINT ENDPOINTS
bookinfo-frontends  autogen.bookinfo-frontends.productpage   240.240.0.2,2001:2::2   None     2/2
istio-gateways      autogen.peering.istio-eastwest.cluster2  240.240.0.16,2001:2::10 None     1/1
monitoring          autogen.monitoring.prometheus            240.240.0.5,2001:2::5   None     1/1
```

productpage is back to two endpoints, and the agent in cluster2 reaches cluster1 again.

| Lifecycle event | Effect on peering | What to run |
|---|---|---|
| The east-west pod moves to another node | istiod in each peer picks up the new node | Nothing, while the xDS link is up |
| The node behind a peer's xDS address is replaced or renumbered | The xDS link drops. Traffic keeps flowing on the last configuration, and changes stop reaching the peer | `check_peer_drift`, then `apply_remote_peers` in each cluster that points at that node |
| `svc/istio-eastwest` is recreated | Same NodePorts, from the chart values | Nothing |
| A cluster is rebuilt with the same mesh name and root CA | New node IPs | Install with labs `002` and `003`, install `peering-eastwest` with the same NodePorts, then run the all-clusters loop |
| A cluster joins | No peering yet | Add it to `ALL_CLUSTERS`, then run the all-clusters loop |
| A cluster leaves | Its global services disappear for the other clusters | Move traffic off it, uninstall its `peering-remote` release, and run the all-clusters loop without it |

> **Upgrades.** An istiod restart re-establishes every xDS connection to the peers, and each connection to a drifted address fails at that point. Run `check_peer_drift` for every pair before you start, as lab `018` does.

## Cleanup

No cleanup is needed. The peering is back to its lab `007` state, and the east-west pod in cluster1 may now run on a different node, which istiod in cluster2 tracks.

## Next Steps
At this point we have completed the following objectives:
- Watched the peer cluster follow an east-west gateway pod to another node
- Checked each remote peer's xDS address and port against the peer cluster
- Lost the xDS link to a peer, saw what kept working and what went stale, and repaired it
- Confirmed that the fixed NodePorts survive a recreated east-west Service
- Took a cluster out of the mesh and brought it back with a loop that works for any number of clusters

In the next step `014` we will serve per-hostname certificates from cert-manager on the ingress gateway
