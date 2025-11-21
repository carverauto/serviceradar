# Tasks

## 1. Implementation
- [x] Fix `serviceradar-config` templating so `nats.conf` and other config keys render and apply
- [x] Adjust NATS config mount to use directory-based config and verify pod starts (NATS now Ready)
- [x] Add missing PVC/secret defaults for core/CNPG consumers (core data PVC, cnpg-superuser secret)
- [x] Disable Proton by default in demo values and remove its deploy from the demo release (no Proton RS/pods)
- [x] Align SPIRE chart with demo manifests (PSAT, projected tokens, controller manager enabled by default for entry reconciliation)
- [x] Run `openspec validate update-helm-demo-chart --strict`

## 2. Validation
- [x] Helm upgrade applies cleanly with the new ConfigMap (check `serviceradar-config` contains `nats.conf`)
- [x] NATS pod ready; dependent pods restartable (but still blocked on SPIRE SVIDs)
- [x] Core pod bound to its PVC and starts without Pending/Init errors (datasvc now obtains SVIDs and is Running; core unblocked by CAGG rebuild in demo; staging has the rebuilt CAGGs via migration 0005)

## 3. Cleanup
- [x] Remove Proton pod/RS from demo namespace (disabled by values)
- [ ] Document the change in the proposal for review/approval

## Notes / Current Blockers
- SPIRE chart mirrors k8s/demo settings (k8s_psat, token audience `spire-server`, projected SA tokens, controller manager on). Agents issue SVIDs; datasvc healthy with SPIFFE.
- Edge onboarding key now auto-generated/seeded via secret-generator job (and settable via values); core picks it up from `serviceradar-secrets`.
- Core connects to CNPG using `spire` user/DB with CNPG CA mounted; the device metrics CAGG SQL is now split into three single-hypertable CAGGs (`device_metrics_summary_cpu|disk|memory`) plus a joining view so Timescale 2.24 accepts it. Need to roll core with the updated migration bundle to clear the CrashLoop.
- Flowgger still crashlooping due to OpenSSL 3.2 dependency mismatch in the image.
