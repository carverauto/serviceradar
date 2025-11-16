## 1. Mirror demo manifests into demo-staging
- [x] 1.1 Clone the `k8s/demo/prod` overlay into `k8s/demo/staging` (or otherwise sync their resource lists) so `kustomize build k8s/demo/staging` renders the same workloads as prod.
- [x] 1.2 Update the `k8s/demo/staging/kustomization.yaml`, `namespace.yaml`, and every manifest under that overlay so the namespace, labels, and service selectors read `demo-staging` instead of `demo` (includes `service-aliases`, `ExternalName` targets, and any hard-coded namespace strings embedded in YAML or scripts).
- [x] 1.3 Adjust ingress resources and annotations to use `demo-staging.serviceradar.cloud` (annotations, TLS secret name, host rules, certificate references) and ensure the TLS secret reference matches the certificate that will back the new hostname.

## 2. Tooling + documentation updates
- [x] 2.1 Update `k8s/demo/README.md`, `DEPLOYMENT.md`, or create a sibling README under `k8s/demo-staging/` to describe the new environment, prerequisites, and how to deploy/validate it.
- [x] 2.2 Teach `k8s/demo/deploy.sh` (or create a `demo-staging` variant) to accept an environment flag so operators can run a single command to apply the new manifest set to the `demo-staging` namespace with the correct secrets/configmap payloads.
- [x] 2.3 Document any DNS/cert-manager prerequisites for `demo-staging.serviceradar.cloud` (external-dns annotation, TLS secret provisioning) inside the repo so ops knows what to configure before applying the manifests.

## 3. Validation
- [x] 3.1 Add a validation step (docs snippet or CI note) that runs `kustomize build k8s/demo/staging | kubeconform` (or `kubectl apply --dry-run`) so we can prove the manifests render successfully.
- [x] 3.2 Capture smoke-test steps for the new namespace (e.g., `kubectl -n demo-staging get ingress,deployments`, hitting `https://demo-staging.serviceradar.cloud/healthz`) once the configuration is applied.
