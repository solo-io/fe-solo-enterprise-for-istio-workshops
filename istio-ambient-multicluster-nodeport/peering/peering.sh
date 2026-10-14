# Peering helpers for labs 007, 013, 018 and 019. Load them with: source peering/peering.sh
#
# apply_remote_peers <context>
#   Installs the peering-remote release in <context>, with one remote peer for every other
#   cluster in ALL_CLUSTERS. Each peer's address is the InternalIP of the first peer node
#   that matches PEER_NODE_SELECTOR. Needs ALL_CLUSTERS, PEER_NODE_SELECTOR,
#   EW_XDS_NODEPORT and PEERING_CHART_VERSION (lab 007).
#
# check_peer_drift <local context> <peer context> <peer mesh name>
#   Compares one remote-peer Gateway with the live state of its peer: the xds-tls port
#   equals the peer's xDS NodePort, the address is still a node in the peer cluster, and
#   PeerConnected is True. Prints OK or one DRIFT line per problem, and returns non-zero
#   on drift.

apply_remote_peers() {
  local LOCAL_CTX=$1 entry ADDR ITEMS=""
  for entry in "${ALL_CLUSTERS[@]}"; do
    [ "${entry%%=*}" = "$LOCAL_CTX" ] && continue
    ADDR=$(kubectl get nodes -l "$PEER_NODE_SELECTOR" --context "${entry%%=*}" \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -z "$ADDR" ]; then
      echo "No node in ${entry%%=*} matches PEER_NODE_SELECTOR=$PEER_NODE_SELECTOR"
      return 1
    fi
    echo "istio-remote-peer-${entry#*=} in $LOCAL_CTX: xDS $ADDR:$EW_XDS_NODEPORT"
    ITEMS="$ITEMS
  - cluster: ${entry#*=}
    network: ${entry#*=}
    trustDomain: ${entry#*=}.local
    address: $ADDR
    nodeport: $EW_XDS_NODEPORT
    preferredDataplaneServiceType: nodeport"
  done
  helm upgrade --install peering-remote oci://us-docker.pkg.dev/soloio-img/istio-helm/peering \
    --version $PEERING_CHART_VERSION-solo -n istio-gateways --kube-context $LOCAL_CTX -f - <<EOF | grep -E "^STATUS"
eastwest:
  create: false
remote:
  create: true
  items:$ITEMS
EOF
}


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
