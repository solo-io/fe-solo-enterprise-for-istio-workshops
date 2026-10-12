## Cleanup

Uninstall Istio and the Bookinfo application on `cluster1` and `cluster2` by running this for loop

```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name

export KUBECONTEXT_CLUSTER2=cluster2  # Replace with your actual kubectl context name
export CLUSTERS=($KUBECONTEXT_CLUSTER1 $KUBECONTEXT_CLUSTER2)
```

The loop below removes every namespace, gateway and Helm release the workshop creates. Deleting the
Gateways first removes the ingress and east-west gateway deployments and their Services, and
the remote-peer Gateways end the peering. The `kubectl get crd` guard keeps the loop safe to rerun after
you remove the CRDs below: `--ignore-not-found` forgives a missing resource but still errors on a
missing CRD.

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  echo "Cleaning up $CONTEXT..."

  # Routes and gateways (labs 005 and 006)
  if kubectl get crd gateways.gateway.networking.k8s.io --context $CONTEXT &>/dev/null; then
    kubectl delete httproute -n bookinfo-frontends --all --context $CONTEXT --ignore-not-found
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
  kubectl get ns --context $CONTEXT --no-headers | grep -E "bookinfo|istio"
  helm list -A --kube-context $CONTEXT -q
done
```

Both commands should print only the `--- <context> ---` lines.

## Istio CRDs

`helm uninstall istio-base` leaves the Istio and Gateway API CRDs in place, which is deliberate: removing
a CRD deletes every custom resource of that kind across the cluster. Leave them if you plan to reinstall.
To remove them on a cluster you are done with:

```bash
for CONTEXT in "${CLUSTERS[@]}"; do
  kubectl get crd --context $CONTEXT -o name \
    | grep -E "istio\.io|gateway\.networking\.k8s\.io" \
    | xargs -r kubectl delete --context $CONTEXT
done
```

## Local files

Lab `002` writes two files into this directory. Remove them once you are finished:

```bash
rm -f shared-root-trust-secret.yaml solo-istioctl
```
