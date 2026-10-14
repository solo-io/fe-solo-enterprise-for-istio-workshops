# Upgrade Both Clusters from 1.28 to 1.29 Under Load, Then Roll Back

# Objectives
- Check peering health before an upgrade, so hidden drift does not turn into an outage mid-upgrade
- Upgrade Istio in place with Helm, one cluster at a time, in Solo's documented order
- Keep cross-cluster traffic flowing while the two clusters run different minor versions
- Measure the request success rate during the upgrade and the rollback
- Roll both clusters back to 1.28 with the same procedure

## Prerequisites
- This lab assumes you have completed setup from labs `000-017`
- Vegeta is installed: see [000-tools.md](000-tools.md#vegeta-cli-load-generator)
- The fixed east-west NodePorts from lab `007` are in place

Ensure the following environment variables are set:
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER2=cluster2    # Recommended to keep as cluster2 for POC
export FROM_VERSION=1.28.10-patch0
export TO_VERSION=1.29.7-patch0
export HELM_REPO=oci://us-docker.pkg.dev/soloio-img/istio-helm
[ -n "$INGRESS_ADDR" ] || echo "⚠️  INGRESS_ADDR is not set. Run the 'Reach the ingress gateway' block from lab 006 in this shell, or its port-forward fallback."
```

## Background

Solo recommends [in-place upgrades with Helm](https://docs.solo.io/istio/1.30.x/ambient/operations/upgrade/manual/) for ambient mode. A revision-based canary that flips revision tags can push empty configuration to Gateway API gateway pods and drop ingress traffic for a moment, so this lab follows the in-place procedure. Each cluster is upgraded on its own, in this order:

| Step | Release | What restarts | Effect on traffic |
|---|---|---|---|
| 1 | `istio-base` | Nothing | Updates the Istio CRDs |
| 2 | `istiod` | istiod, then every gateway and waypoint that istiod manages | Gateways roll to the new proxy image, one pod at a time |
| 3 | `istio-cni` | The `istio-cni-node` DaemonSet | New pods on a node wait until the new CNI agent is ready. Running pods are unaffected |
| 4 | `ztunnel` | The `ztunnel` DaemonSet, one node at a time | Connections through a node's ztunnel close when that ztunnel restarts |

The peered clusters keep working while one runs 1.28 and the other 1.29. The `peering-eastwest` and `peering-remote` releases from lab `007` stay at the `1.29.7-patch0` chart.

> **Why not `helm upgrade --reuse-values`?** `--reuse-values` keeps the old release's values and skips the new chart's defaults. The 1.29 ztunnel chart reads a value that 1.28 never set, and the upgrade fails with `executing "ztunnel/templates/daemonset.yaml" at <.Values.peerCaCrl.enabled>: nil pointer evaluating interface {}.enabled`. Export the values you set with `helm get values`, change the version in that file, and pass it with `-f`, so the new chart's defaults fill in the rest.

## Check the Mesh Before You Start

Check the peering from both sides and confirm that the remote-peer Gateways match their peers. An istiod restart re-establishes every xDS connection to the peers, so an upgrade is when drift from lab `013` would surface. The function is the same `check_peer_drift` from lab `013`:
```bash
check_peer_drift() {
  local LOCAL_CTX=$1 PEER_CTX=$2 PEER_MESH=$3 GW WANT_XDS HAVE_XDS PEER_NODE_IPS ADDR CONNECTED STATUS=OK
  GW=istio-remote-peer-$PEER_MESH
  WANT_XDS=$(kubectl get svc istio-eastwest -n istio-gateways --context $PEER_CTX -o jsonpath='{.spec.ports[?(@.port==15012)].nodePort}')
  HAVE_XDS=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.listeners[?(@.name=="xds-tls")].port}')
  ADDR=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.spec.addresses[0].value}')
  CONNECTED=$(kubectl get gateway $GW -n istio-gateways --context $LOCAL_CTX -o jsonpath='{.status.conditions[?(@.type=="gloo.solo.io/PeerConnected")].status}')
  PEER_NODE_IPS=" $(kubectl get nodes --context $PEER_CTX -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address} {end}')"
  if [ "$WANT_XDS" != "$HAVE_XDS" ]; then
    echo "DRIFT  $LOCAL_CTX/$GW: xDS port $HAVE_XDS, $PEER_CTX xDS NodePort is $WANT_XDS"
    STATUS=DRIFT
  fi
  case "$PEER_NODE_IPS" in
    *" $ADDR "*) ;;
    *) echo "DRIFT  $LOCAL_CTX/$GW: address $ADDR is not a node in $PEER_CTX"; STATUS=DRIFT ;;
  esac
  if [ "$CONNECTED" != "True" ]; then
    echo "DRIFT  $LOCAL_CTX/$GW: PeerConnected=$CONNECTED"
    STATUS=DRIFT
  fi
  [ $STATUS = OK ] && echo "OK     $LOCAL_CTX/$GW: $ADDR:$HAVE_XDS connected"
  [ $STATUS = OK ]
}

check_peer_drift $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2" 2>&1 | grep -A1 "Peers Check"
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  helm list -n istio-system --kube-context $context -o yaml | grep -E "^  (name|chart):" | paste - - | awk -v c=$context '{print c, $2, $4}'
done
```

Expected output:
```
OK     cluster1/istio-remote-peer-cluster2: 172.30.0.4:31512 connected
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2:31512 connected
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
✅ Peers Check: all clusters connected
     ✅ Connected to cluster1 via 172.30.0.2
cluster1 base-1.28.10-patch0-solo istio-base
cluster1 cni-1.28.10-patch0-solo istio-cni
cluster1 istiod-1.28.10-patch0-solo istiod
cluster1 ztunnel-1.28.10-patch0-solo ztunnel
cluster2 base-1.28.10-patch0-solo istio-base
cluster2 cni-1.28.10-patch0-solo istio-cni
cluster2 istiod-1.28.10-patch0-solo istiod
cluster2 ztunnel-1.28.10-patch0-solo ztunnel
```

Fix any `DRIFT` line before you go on.

## Define the Upgrade Step

The function below moves one Helm release from one version to another, the way Solo's procedure describes: it exports the values you set, replaces the version in them, upgrades with `-f`, and waits for the rollout. The values files go into `upgrade-values/`, which is gitignored, because the `istiod` values contain your license key:
```bash
mkdir -p upgrade-values
move_release() {
  local CTX=$1 RELEASE=$2 CHART=$3 FROM=$4 TO=$5 FILE=upgrade-values/$2-$1.yaml
  helm get values $RELEASE -n istio-system --kube-context $CTX -o yaml > $FILE
  sed -i.bak "s/$FROM-solo/$TO-solo/g" $FILE && rm -f $FILE.bak
  helm upgrade $RELEASE $HELM_REPO/$CHART -n istio-system --kube-context $CTX --version $TO-solo -f $FILE \
    | grep -E "^STATUS"
  case $RELEASE in
    istiod)    kubectl rollout status deploy/istiod -n istio-system --watch --timeout=180s --context $CTX ;;
    istio-cni) kubectl rollout status ds/istio-cni-node -n istio-system --watch --timeout=180s --context $CTX ;;
    ztunnel)   kubectl rollout status ds/ztunnel -n istio-system --watch --timeout=300s --context $CTX ;;
  esac
}
```

`sed -i.bak` works with both GNU and BSD `sed`.

## Start the Load

Send every request across the clusters for the whole lab: scale productpage to zero in cluster1, so the cluster1 ingress gateway sends each request through the east-west gateway to cluster2. Then start Vegeta at 10 requests per second, writing results to a file until you stop it:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 0 --context $KUBECONTEXT_CLUSTER1
kubectl wait --for=delete pod -l app=productpage -n bookinfo-frontends --timeout=60s --context $KUBECONTEXT_CLUSTER1
curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[12]" | head -1
echo "GET http://$INGRESS_ADDR/productpage" | vegeta attack -rate=10 -duration=0 > upgrade-load.bin &
LOAD_PID=$!
```

Expected output:
```
cluster2
```

Define a helper that reports the results so far, without stopping the load:
```bash
load_report() {
  cp upgrade-load.bin upgrade-load-snapshot.bin
  vegeta report -type=text < upgrade-load-snapshot.bin 2>/dev/null | grep -E "^(Requests|Success|Status Codes)"
}
```

## Upgrade cluster2

Upgrade the cluster that serves the traffic first. `istio-base` updates the CRDs, then `istiod`:
```bash
move_release $KUBECONTEXT_CLUSTER2 istio-base base    $FROM_VERSION $TO_VERSION
move_release $KUBECONTEXT_CLUSTER2 istiod     istiod  $FROM_VERSION $TO_VERSION
```

Expected output:
```
STATUS: deployed
STATUS: deployed
Waiting for deployment "istiod" rollout to finish: 1 old replicas are pending termination...
deployment "istiod" successfully rolled out
```

The new istiod updates the proxies it manages. Watch the waypoint and the east-west gateway move to the new image:
```bash
sleep 20
kubectl get pods -n bookinfo-backends -l gateway.networking.k8s.io/gateway-name=waypoint --context $KUBECONTEXT_CLUSTER2 \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image}{"\n"}{end}'
kubectl get pods -n istio-gateways --context $KUBECONTEXT_CLUSTER2 \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image}{"\n"}{end}'
```

Expected output:
```
waypoint-6fb5c8dc94-dxjzb us-docker.pkg.dev/soloio-img/istio/proxyv2:1.29.7-patch0-solo-distroless
istio-eastwest-78847468c9-n7dqc us-docker.pkg.dev/soloio-img/istio/ztunnel:1.29.7-patch0-solo-distroless
```

The east-west gateway runs the ztunnel image, and the waypoint runs the Envoy-based `proxyv2` image. istiod rolled both without a Helm change. Upgrade the CNI agent and ztunnel. Helm prints a Kubernetes deprecation warning for the `container.apparmor.security.beta.kubernetes.io/install-cni` annotation in the CNI chart, which does not affect the upgrade:
```bash
move_release $KUBECONTEXT_CLUSTER2 istio-cni cni     $FROM_VERSION $TO_VERSION
move_release $KUBECONTEXT_CLUSTER2 ztunnel   ztunnel $FROM_VERSION $TO_VERSION
```

Check the mixed-version mesh: cluster1 on 1.28, cluster2 on 1.29:
```bash
./solo-istioctl multicluster check --contexts="$KUBECONTEXT_CLUSTER1,$KUBECONTEXT_CLUSTER2" 2>&1 | grep -A1 "Peers Check"
curl -s http://$INGRESS_ADDR/productpage | grep -oE "cluster[12]" | head -1
load_report
```

Expected output (a request in flight during a proxy restart can lower the success ratio, see [Roll Back to 1.28](#roll-back-to-128)):
```
✅ Peers Check: all clusters connected
     ✅ Connected to cluster2 via 172.30.0.4
✅ Peers Check: all clusters connected
     ✅ Connected to cluster1 via 172.30.0.2
cluster2
Requests      [total, rate, throughput]         628, 10.02, 10.01
Success       [ratio]                           100.00%
Status Codes  [code:count]                      200:628  
```

Every request so far crossed from agentgateway in cluster1, with its 1.28 mesh peers, to the 1.29 data plane in cluster2. In this run all of them succeeded.

## Upgrade cluster1

Run the same four steps in cluster1:
```bash
move_release $KUBECONTEXT_CLUSTER1 istio-base base    $FROM_VERSION $TO_VERSION
move_release $KUBECONTEXT_CLUSTER1 istiod     istiod  $FROM_VERSION $TO_VERSION
move_release $KUBECONTEXT_CLUSTER1 istio-cni  cni     $FROM_VERSION $TO_VERSION
move_release $KUBECONTEXT_CLUSTER1 ztunnel    ztunnel $FROM_VERSION $TO_VERSION
```

> **agentgateway during the upgrade.** agentgateway has its own Helm release, so the Istio upgrade leaves its pods running. It keeps the mesh certificate that istiod issued, and opens HBONE connections to 1.28 and 1.29 ztunnels alike. Upgrade agentgateway on its own release cycle, with the Helm commands from lab `005`.

Check that every Istio image in both clusters is now 1.29, and that the peering and the load are healthy:
```bash
sleep 20
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  echo "== $context"
  kubectl get pods -A --context $context --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep soloio-img | sed 's#.*/##' | sort | uniq -c
done
check_peer_drift $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2 $MESH_NAME_CLUSTER2
check_peer_drift $KUBECONTEXT_CLUSTER2 $KUBECONTEXT_CLUSTER1 $MESH_NAME_CLUSTER1
load_report
```

Expected output (the success ratio can be below 100 percent, as above):
```
== cluster1
   2 install-cni:1.29.7-patch0-solo-distroless
   1 pilot:1.29.7-patch0-solo-distroless
   1 proxyv2:1.29.7-patch0-solo-distroless
   3 ztunnel:1.29.7-patch0-solo-distroless
== cluster2
   2 install-cni:1.29.7-patch0-solo-distroless
   1 pilot:1.29.7-patch0-solo-distroless
   1 proxyv2:1.29.7-patch0-solo-distroless
   3 ztunnel:1.29.7-patch0-solo-distroless
OK     cluster1/istio-remote-peer-cluster2: 172.30.0.4:31512 connected
OK     cluster2/istio-remote-peer-cluster1: 172.30.0.2:31512 connected
Requests      [total, rate, throughput]         1242, 10.01, 10.01
Success       [ratio]                           100.00%
Status Codes  [code:count]                      200:1242  
```

Each cluster has three ztunnel-image pods, two node ztunnels and the east-west gateway, and one `proxyv2` pod, the waypoint. The agentgateway pods use their own images, so the list does not show them. The fixed NodePorts from lab `007` kept the xDS ports unchanged through the upgrade, and both peers reconnected to the new istiod, so the drift check still passes. In this run both upgrades finished with no failed requests.

> **New in 1.29: endpoint health metrics.** ztunnel 1.29 exports `istio_outlier_detection_endpoints` and `istio_outlier_detection_endpoints_unhealthy`. They count the endpoints that ztunnel has taken out of rotation, such as the cluster1 productpage pod in lab `008` after policy rejections. Add `istio_outlier_detection_.*` to the lab `011` keep-list to chart them.

## Roll Back to 1.28

Rolling back is the same procedure with the versions swapped, in reverse cluster order. `istio-base` stays at 1.29: newer CRDs serve the older istiod, and moving CRDs back can drop fields that resources created during the upgrade already use.

`helm rollback` goes to the previous Helm revision. After a failed upgrade attempt, that revision is the failed one, so name the version explicitly instead:
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  move_release $context istiod    istiod  $TO_VERSION $FROM_VERSION
  move_release $context istio-cni cni     $TO_VERSION $FROM_VERSION
  move_release $context ztunnel   ztunnel $TO_VERSION $FROM_VERSION
done
sleep 20
```

Stop the load and read the final report:
```bash
kill -INT $LOAD_PID
sleep 2
vegeta report -type=text < upgrade-load.bin | grep -E "^(Requests|Success|Status Codes)"
vegeta encode --to csv < upgrade-load.bin | awk -F, '$2 != 200 { print $1, $2, $6 }' | while read TS CODE ERR; do
  echo "$(date -r $((TS / 1000000000)) +%T 2>/dev/null || date -d @$((TS / 1000000000)) +%T) $CODE $ERR"
done
```

Expected output (the request count differs with how long the upgrade took):
```
Requests      [total, rate, throughput]         2152, 10.00, 10.00
Success       [ratio]                           100.00%
Status Codes  [code:count]                      200:2152  
```

The second command prints one line per failed request, and printed none in this run. In two other validation runs of the same steps, 2 requests failed each time:
```
17:32:45 503 503 Service Unavailable
17:33:12 503 503 Service Unavailable
```

A proxy on the cross-cluster path restarted while the request was in flight and closed its connection, so the gateway answered `503`. Two rollouts restart a proxy on that path:

- The ztunnel rollout in cluster2. agentgateway's connections to productpage go through the ztunnel on productpage's node.
- The east-west gateway rollout that follows the istiod upgrade in cluster2. Every request in this lab crosses the cluster2 east-west gateway, and the new istiod replaces its pod within seconds of the upgrade.

Whether a restart hits a request depends on timing, so plan for a small number of resets during each ztunnel rollout and each istiod upgrade.

> **Reduce ztunnel restart impact in production.** A ztunnel restart closes the connections through that node. Solo's [ztunnel tuning guide](https://docs.solo.io/istio/1.30.x/ambient/operations/ztunnel-tuning/) covers the termination grace period. Upgrade ztunnel node by node with the node cordoned and its workloads moved first, or roll new node pools in, so that no ztunnel restarts under live traffic. Clients that retry idempotent requests absorb the rest.

Confirm that both clusters are back on 1.28:
```bash
for context in $KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2; do
  helm list -n istio-system --kube-context $context -o yaml | grep -E "^  (name|chart):" | paste - - | awk -v c=$context '{print c, $2, $4}'
done
```

Expected output:
```
cluster1 base-1.29.7-patch0-solo istio-base
cluster1 cni-1.28.10-patch0-solo istio-cni
cluster1 istiod-1.28.10-patch0-solo istiod
cluster1 ztunnel-1.28.10-patch0-solo ztunnel
cluster2 base-1.29.7-patch0-solo istio-base
cluster2 cni-1.28.10-patch0-solo istio-cni
cluster2 istiod-1.28.10-patch0-solo istiod
cluster2 ztunnel-1.28.10-patch0-solo ztunnel
```

## Cleanup

Bring productpage back in cluster1, and remove the load results and the values files, which contain your license key:
```bash
kubectl scale deploy/productpage-v1 -n bookinfo-frontends --replicas 1 --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/productpage-v1 -n bookinfo-frontends --watch --timeout=90s --context $KUBECONTEXT_CLUSTER1
rm -f upgrade-load.bin upgrade-load-snapshot.bin
rm -rf upgrade-values
```

## Next Steps
At this point we have completed the following objectives:
- Checked peering health before the upgrade, so hidden drift could not turn into an outage mid-upgrade
- Upgraded Istio in place with Helm, one cluster at a time, in Solo's documented order
- Kept cross-cluster traffic flowing while the two clusters ran different minor versions
- Measured the request success rate during the upgrade and the rollback
- Rolled both clusters back to 1.28 with the same procedure

In the next step `019` we will add two more clusters and peer all four over NodePort
