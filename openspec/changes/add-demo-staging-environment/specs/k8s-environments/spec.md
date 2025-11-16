## ADDED Requirements
### Requirement: Demo-staging manifests mirror the demo deployment
ServiceRadar MUST ship a `k8s/demo/staging` overlay whose rendered output is configuration-identical to `k8s/demo/prod` except for the namespace/hostname values so engineers can rehearse demo changes without touching the live namespace.

#### Scenario: Kustomize render targets the demo-staging namespace
- **GIVEN** the repository checkout contains the new manifest tree
- **WHEN** `kustomize build k8s/demo/staging` runs
- **THEN** the output includes every workload from `k8s/demo/prod` and all generated YAML documents declare `metadata.namespace: demo-staging` (or rely on `namespace: demo-staging` at the Kustomize level) instead of `demo`.

#### Scenario: Service aliases follow demo-staging FQDNs
- **GIVEN** the new manifests are applied to a cluster
- **WHEN** `kubectl get service core -n demo-staging -o yaml` (and the other alias Services) runs
- **THEN** each `spec.externalName` points at `*.demo-staging.svc.cluster.local`, matching the pods that run in that namespace.

### Requirement: Demo-staging ingress and DNS use demo-staging.serviceradar.cloud
The demo-staging overlay MUST publish an ingress that front-ends the namespace via `demo-staging.serviceradar.cloud`, carries a unique TLS secret, and exposes the same path rules as the primary demo ingress so any UI/API smoke tests behave the same way.

#### Scenario: External-DNS annotation advertises the new hostname
- **GIVEN** the ingress manifest inside `k8s/demo/staging`
- **WHEN** it is inspected
- **THEN** it sets `external-dns.alpha.kubernetes.io/hostname: "demo-staging.serviceradar.cloud"` and the TLS block lists `demo-staging.serviceradar.cloud` so cert-manager knows which certificate to request.

#### Scenario: HTTP routing matches the demo ingress
- **GIVEN** `kubectl get ingress serviceradar-ingress -n demo-staging -o yaml`
- **WHEN** you compare its `spec.rules[].http.paths` with the demo ingress
- **THEN** it exposes the `_next`, `/api/stream`, `/api/*`, `/auth`, and `/` routes so web, Kong, and core all receive traffic just like they do in the demo namespace.

### Requirement: Deployment docs and tooling cover demo-staging
We MUST document how to deploy, configure secrets, and validate workloads in the new namespace so operators can spin it up repeatedly without reverse-engineering the manifests.

#### Scenario: Deploy script or README describes demo-staging steps
- **GIVEN** a teammate reads `k8s/demo/README.md`, `k8s/demo/deploy.sh`, or a sibling document dedicated to the new environment
- **WHEN** they follow the documented steps
- **THEN** they learn how to create the `demo-staging` namespace, generate the required secrets/configmap, run `kubectl apply -k k8s/demo/staging`, and validate that `https://demo-staging.serviceradar.cloud` answers.
