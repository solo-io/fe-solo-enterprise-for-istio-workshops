# Changelog

0.0.2 - (10-12-26)
---
- Add `style-guide.md`: lab authoring conventions audited from the full workshop corpus (skeleton, command idioms, verification, cleanup, sibling-workshop sync, repo maintenance checklist)
- Add `istio-ambient-multicluster-nodeport` workshop: peers two clusters through NodePort east-west gateways with no LoadBalancer, following Solo's multi-cluster NodePort reference architecture
- Update `README.md` (workshop row, `Multicluster NodePort (K8s)` use-case column, versions note)

0.0.1 - (10-6-26)
---
- Bump Solo Istio from `1.30.2-solo` to `1.30.5-solo` across all workshops (Helm charts, `-solo-distroless` images, `ISTIO_VERSION` exports, version tables)
- Bump `docker.io/istio/app` from `1.30.2` to `1.30.5` and drop the `@sha256` digest pin from the gRPC manifests
- Add `lib/mirror-images.sh` to copy each workshop's prerequisite images (all architectures) to a private registry for air-gapped runs

0.0.0 - (10-5-26)
---
- Move resources from personal `ably77/solo-enterprise-for-istio-workshops` github repo to `solo-io/fe-solo-enterprise-for-istio-workshops`