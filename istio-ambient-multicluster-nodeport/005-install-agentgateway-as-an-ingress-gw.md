# Install Agentgateway as the Ingress Gateway

# Objectives
- Install Solo Enterprise for agentgateway on cluster1
- Deploy an `ingress` Gateway that joins the ambient mesh through Istio integration
- Check the mesh identity the gateway presents to workloads

## Prerequisites
- This lab assumes you have completed setup from labs `000-004`

## Set cluster contexts
In this workshop, you can use your preferred cluster context. To set it, run the following command, replacing cluster1 with your desired context name
```bash
export KUBECONTEXT_CLUSTER1=cluster1  # Replace with your actual kubectl context name
export MESH_NAME_CLUSTER1=cluster1    # Recommended to keep as cluster1 for POC
```

Export your Solo Trial License Key and the agentgateway version
```bash
export SOLO_TRIAL_LICENSE_KEY=<paste-your-key>
[ -n "$SOLO_TRIAL_LICENSE_KEY" ] || echo "⚠️  SOLO_TRIAL_LICENSE_KEY is not set. The agentgateway controller needs a license to program gateways."
export ENTERPRISE_AGW_VERSION=v2026.9.3
```

## Background

Solo Enterprise for agentgateway is the north-south gateway in this workshop. Customer traffic enters through it in every later lab, and lab `017` migrates ingress-nginx objects onto it.

agentgateway joins the mesh through its Istio integration. It requests a workload certificate from istiod for its own identity and opens HBONE connections to ztunnel itself, so a request from the gateway to productpage is mTLS from the first hop. The gateway pod stays outside ztunnel's traffic capture. Enrolling the pod with the `istio.io/dataplane-mode=ambient` label instead would make ztunnel inspect the plaintext connections from clients and the load balancer, and the `STRICT` mTLS policy from lab `008` rejects those.

East-west traffic between the clusters and the waypoints in lab `009` stay on Istio. agentgateway only replaces the ingress.

## Check the Gateway API CRDs

agentgateway uses the Gateway API CRDs that lab `002` installed. That is the release Istio 1.28 is built against:
```bash
kubectl get crd gateways.gateway.networking.k8s.io --context $KUBECONTEXT_CLUSTER1 \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

Expected output:
```
v1.4.1
```

## Install the Agentgateway Charts

Install the CRD chart and the controller chart in the `agentgateway-system` namespace
```bash
kubectl create namespace agentgateway-system --context $KUBECONTEXT_CLUSTER1 --dry-run=client -o yaml | kubectl apply --context $KUBECONTEXT_CLUSTER1 -f -

helm upgrade -i --kube-context $KUBECONTEXT_CLUSTER1 -n agentgateway-system \
  --version $ENTERPRISE_AGW_VERSION enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds

helm upgrade -i --kube-context $KUBECONTEXT_CLUSTER1 -n agentgateway-system \
  --version $ENTERPRISE_AGW_VERSION enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --set-string licensing.licenseKey=$SOLO_TRIAL_LICENSE_KEY
```

Wait for the controller, and check the GatewayClasses it registers
```bash
kubectl rollout status deploy/enterprise-agentgateway -n agentgateway-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl get gatewayclass --context $KUBECONTEXT_CLUSTER1
```

Expected output:
```
deployment "enterprise-agentgateway" successfully rolled out
NAME                               CONTROLLER                        ACCEPTED   AGE
enterprise-agentgateway            solo.io/enterprise-agentgateway   True       1s
enterprise-agentgateway-waypoint   solo.io/enterprise-agentgateway   True       1s
istio                              istio.io/gateway-controller       True       54s
istio-eastwest                     istio.io/eastwest-controller      True       54s
istio-remote                       istio.io/unmanaged-gateway        True       54s
istio-waypoint                     istio.io/mesh-controller          True       54s
```

`enterprise-agentgateway` is the class for the ingress gateway. `enterprise-agentgateway-waypoint` runs agentgateway as a waypoint, which this workshop does not use. The `istio-*` classes belong to Istio: lab `007` uses `istio-eastwest` and `istio-remote` for peering, and lab `009` uses `istio-waypoint`.

## Deploy the Ingress Gateway

The `EnterpriseAgentgatewayParameters` resource holds the gateway's infrastructure settings. Its `istio` block turns on the mesh integration, with the same trust domain, cluster name and network as istiod in lab `002`. The `Gateway` references it through `spec.infrastructure.parametersRef`:
```bash
kubectl apply --context $KUBECONTEXT_CLUSTER1 -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ingress-config
  namespace: agentgateway-system
spec:
  istio:
    enabled: true
    trustDomain: $MESH_NAME_CLUSTER1.local
    clusterId: $MESH_NAME_CLUSTER1
    network: $MESH_NAME_CLUSTER1
  service:
    spec:
      # Change to NodePort if your cluster has no LoadBalancer integration
      type: LoadBalancer
---
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
```

Wait for the gateway to be programmed, then check the pods and the Service
```bash
kubectl wait --for=condition=Programmed gateway/ingress -n agentgateway-system --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl rollout status deploy/ingress -n agentgateway-system --watch --timeout=120s --context $KUBECONTEXT_CLUSTER1
kubectl get pods -n agentgateway-system --context $KUBECONTEXT_CLUSTER1
kubectl get svc ingress -n agentgateway-system --context $KUBECONTEXT_CLUSTER1
```

Expected output (pod suffixes and addresses differ on your machine):
```
gateway.gateway.networking.k8s.io/ingress condition met
deployment "ingress" successfully rolled out
NAME                                                        READY   STATUS    RESTARTS   AGE
enterprise-agentgateway-8d9747d68-xjfz9                     1/1     Running   0          24s
ext-auth-service-enterprise-agentgateway-59c48ddf55-f4ng6   1/1     Running   0          20s
ext-cache-enterprise-agentgateway-85d84576f9-jj5pz          1/1     Running   0          21s
ingress-55cd48866f-8bgcj                                    1/1     Running   0          21s
rate-limiter-enterprise-agentgateway-6c64497d6b-8xnwp       1/1     Running   0          21s
waf-server-enterprise-agentgateway-669566c8dd-m2fq8         1/1     Running   0          21s
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
ingress   LoadBalancer   10.111.90.138   172.30.255.254   80:31519/TCP   21s
```

The `ingress` pod is the gateway. The other pods are agentgateway's controller and its add-on services for rate limiting, external auth, caching and WAF, which this workshop does not configure.

> **Note:** The cloud load balancer may take a few minutes to be provisioned. If `EXTERNAL-IP` shows `<pending>`, wait and re-run the `kubectl get svc` command. Lab `006` covers clusters without a load balancer.

## Check the Gateway's Mesh Identity

ztunnel lists the gateway pod as a workload with protocol `TCP`, because the pod is outside ztunnel's capture. The gateway still holds a mesh certificate and speaks HBONE to the workloads it calls:
```bash
./solo-istioctl zc workloads -n istio-system --context $KUBECONTEXT_CLUSTER1 | grep -E "NAMESPACE|agentgateway-system +ingress"
kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=ingress \
  --context $KUBECONTEXT_CLUSTER1 -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

Expected output:
```
NAMESPACE           POD NAME                                                  ADDRESS     NODE     WAYPOINT PROTOCOL
agentgateway-system ingress-55cd48866f-8bgcj                                  10.244.1.42 worker-1 None     TCP
ingress
```

The gateway runs as the `ingress` service account in `agentgateway-system`, so workloads see the caller `spiffe://cluster1.local/ns/agentgateway-system/sa/ingress`. The access policies in lab `008` allow that identity, and lab `007` shows it in the ztunnel logs of cluster2.

> **Ingress in more than one cluster.** This workshop runs the ingress gateway in cluster1 only. In production, run this lab in each cluster that receives customer traffic, with that cluster's mesh name in the `istio` block. Lab `012` covers the routing side.

## Cleanup

No cleanup is needed. The gateway serves every later lab, and lab `020` removes it.

## Next Steps
At this point we have completed the following objectives:
- Installed Solo Enterprise for agentgateway on cluster1
- Deployed an `ingress` Gateway that joins the ambient mesh through Istio integration
- Checked the mesh identity the gateway presents to workloads

In the next step `006` we will expose Bookinfo through agentgateway
