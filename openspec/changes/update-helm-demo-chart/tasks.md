# Tasks

## 1. Implementation
- [ ] Fix `serviceradar-config` templating so `nats.conf` and other config keys render and apply
- [ ] Adjust NATS config mount to use directory-based config and verify pod starts
- [ ] Add missing PVC/secret defaults for core/CNPG consumers (core data PVC, cnpg-superuser secret)
- [ ] Disable Proton by default in demo values and remove its deploy from the demo release
- [ ] Keep SPIRE controller manager optional/off for demo Helm deploys
- [ ] Run `openspec validate update-helm-demo-chart --strict`

## 2. Validation
- [ ] Helm upgrade applies cleanly with the new ConfigMap (check `serviceradar-config` contains `nats.conf`)
- [ ] NATS pod ready; dependent pods (datasvc/sync/web/flowgger/otel) leave CrashLoopBackOff after restart
- [ ] Core pod bound to its PVC and starts without Pending/Init errors

## 3. Cleanup
- [ ] Remove Proton pod/RS from demo namespace (disabled by values)
- [ ] Document the change in the proposal for review/approval
