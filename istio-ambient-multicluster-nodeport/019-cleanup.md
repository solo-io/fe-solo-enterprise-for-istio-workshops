## Cleanup

Uninstall Istio, the Bookinfo application and everything the add-on labs created on `cluster1` and `cluster2`, and on `cluster3` and `cluster4` if you ran lab `018`. Set the contexts first

```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name

export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export CLUSTERS=($KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2)
```

If you ran lab `018`, add its two clusters to the list
```bash
export KUBECONTEXT_CLUSTER3=cluster3  # Replace with your actual kubectl context name
export KUBECONTEXT_CLUSTER4=cluster4  # Replace with your actual kubectl context name
CLUSTERS+=($KUBECONTEXT_CLUSTER3 $KUBECONTEXT_CLUSTER4)
```

## Add-on labs (labs `007`-`018`)

Each add-on lab removes its own resources in its `## Cleanup` section. The loop below removes anything left over, for example after a lab you stopped partway through. Every delete uses `--ignore-not-found`, so the loop is safe to run when a lab already cleaned up:

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  echo "Cleaning up add-on labs in $CONTEXT..."

  # Namespaces: tenant-a (007), perf (009), monitoring (010), cert-manager (013),
  # client-ip and outside (014), egress and partner (015), grpc-echo (016)
  kubectl delete namespace tenant-a perf monitoring cert-manager client-ip outside egress partner grpc-echo \
    --context $CONTEXT --ignore-not-found

  # Prometheus RBAC (010)
  kubectl delete clusterrolebinding prometheus-mesh --context $CONTEXT --ignore-not-found
  kubectl delete clusterrole prometheus-mesh --context $CONTEXT --ignore-not-found

  # Egress node label (015)
  kubectl label node -l egress-node=true egress-node- --context $CONTEXT

  # Probe pods in the default namespace (015, 018)
  kubectl delete pod egress-probe reach-probe -n default --context $CONTEXT --ignore-not-found
done

# cert-manager release (013), if the lab was stopped before its cleanup
helm uninstall cert-manager -n cert-manager --kube-context $KUBECONTEXT_CLUSTER1 --ignore-not-found
```

The `ingress-edge` Gateway and its ConfigMap (lab `014`), the NodePort pins (labs `012` and `018`), the waypoints (lab `008`) and every `AuthorizationPolicy` and `PeerAuthentication` (labs `007`, `008`, `010`) live in namespaces that the next section deletes.

## Istio, gateways and Bookinfo (labs `001`-`006`)

The loop below removes every namespace, gateway and Helm release the core labs create. Deleting the
Gateways first removes the ingress and east-west gateway deployments and their Services, and
the remote-peer Gateways end the peering. The `kubectl get crd` guard keeps the loop safe to rerun after
you remove the CRDs below: `--ignore-not-found` forgives a missing resource but still errors on a
missing CRD.

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  echo "Cleaning up $CONTEXT..."

  # Routes and gateways (labs 005, 006, 008, 014, 018)
  if kubectl get crd gateways.gateway.networking.k8s.io --context $CONTEXT &>/dev/null; then
    kubectl delete httproute,grpcroute -n bookinfo-frontends --all --context $CONTEXT --ignore-not-found
    kubectl delete gateways -n bookinfo-backends --all --context $CONTEXT --ignore-not-found
    kubectl delete gateways -n istio-gateways --all --context $CONTEXT --ignore-not-found
    kubectl delete gateways -n istio-system --all --context $CONTEXT --ignore-not-found
  fi

  # Istio
  helm uninstall ztunnel -n istio-system --kube-context $CONTEXT --ignore-not-found
  helm uninstall istiod -n istio-system --kube-context $CONTEXT --ignore-not-found
  helm uninstall istio-cni -n istio-system --kube-context $CONTEXT --ignore-not-found
  helm uninstall istio-base -n istio-system --kube-context $CONTEXT --ignore-not-found

  # Namespaces: bookinfo (lab 001), istio-system (labs 002 and 003), istio-gateways (lab 006)
  kubectl delete ns bookinfo-frontends bookinfo-backends istio-gateways istio-system \
    --context $CONTEXT --ignore-not-found
done
```

Confirm nothing is left:

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  echo "--- $CONTEXT ---"
  kubectl get ns --context $CONTEXT --no-headers | grep -E "bookinfo|istio|tenant-a|perf|monitoring|cert-manager|client-ip|outside|egress|partner|grpc-echo"
  helm list -A --kube-context $CONTEXT -q
done
```

Both commands should print only the `--- <context> ---` lines.

## CRDs

`helm uninstall istio-base` leaves the Istio and Gateway API CRDs in place, and `helm uninstall cert-manager` (lab `013`) leaves the cert-manager CRDs. This is deliberate: removing
a CRD deletes every custom resource of that kind across the cluster. Leave them if you plan to reinstall.
To remove them on a cluster you are done with:

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  kubectl get crd --context $CONTEXT -o name \
    | grep -E "istio\.io|gateway\.networking\.k8s\.io|cert-manager\.io" \
    | xargs -r kubectl delete --context $CONTEXT
done
```

## Local files

Lab `002` writes two files into this directory, and labs `011`, `013`, `016` and `017` write files that their own cleanup removes. Remove all of them once you are finished:

```bash
rm -f shared-root-trust-secret.yaml solo-istioctl
rm -f canary-targets.txt canary-report.txt internal-root-ca.pem ingress2gateway upgrade-load.bin upgrade-load-snapshot.bin
rm -rf upgrade-values
```
