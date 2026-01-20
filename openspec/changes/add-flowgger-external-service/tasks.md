# Tasks: Add Flowgger External Service

## 1. Helm Chart Updates

- [x] 1.1 Add `flowgger.externalService` configuration block to `values.yaml`
  - `enabled: false` (default)
  - `type: LoadBalancer`
  - `annotations: {}` (for metallb.universe.tf/address-pool, etc.)
  - `loadBalancerIP: ""` (optional static IP)
  - `ports` configuration for UDP 514 and optionally NetFlow UDP 2055
- [x] 1.2 Update `helm/serviceradar/templates/flowgger.yaml` to conditionally render external service
- [x] 1.3 Add `values-demo.yaml` overrides for demo environment MetalLB configuration

## 2. K8s Manifest Cleanup

- [x] 2.1 Remove `k8s/demo/staging/serviceradar-flowgger-external.yaml` (helm will manage this)
- [x] 2.2 Update `k8s/demo/staging/kustomization.yaml` to remove external service reference

## 3. Documentation

- [x] 3.1 Add comments in values.yaml explaining external service configuration
- [ ] 3.2 Document MetalLB and cloud provider annotation examples (in README or docs)

## 4. Validation

- [x] 4.1 Run `helm template` to verify external service renders correctly
- [ ] 4.2 Deploy to demo-staging with `helm upgrade` and verify LoadBalancer gets external IP
- [ ] 4.3 Test syslog traffic reaches flowgger through external IP
