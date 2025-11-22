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
- [ ] Agent pod starts and reaches KV (currently crashlooping: `failed to load config: ... name resolver error: produced zero addresses` in demo)
- [ ] DB event writer starts with SPIFFE TLS (currently `x509svid: could not verify leaf certificate` when connecting in demo)
- [ ] Flowgger image fixed to run on cluster OpenSSL (currently `libcrypto.so.3: OPENSSL_3.2.0 not found`)

## 3. Cleanup
- [x] Remove Proton pod/RS from demo namespace (disabled by values)
- [x] Document the change in the proposal for review/approval

## 4. Recent Fixes (db-event-writer)
- [x] Fixed SPIFFE bundle delivery: Added `SPIFFE_ENDPOINT_SOCKET` to `serviceradar-datasvc` deployment to ensure `go-spiffe` initializes correctly.
- [x] Fixed DB Authentication: Enabled `enableSuperuserAccess: true` in `spire-postgres.yaml` (CNPG Cluster) to allow `postgres` user authentication.
- [x] Fixed DB Configuration: Updated `db-event-writer` to use the correct `spire` database (via `CNPG_DATABASE` env var and ConfigMap update) instead of the non-existent `telemetry` database.

## Notes / Current Blockers
- SPIRE chart mirrors k8s/demo settings (k8s_psat, token audience `spire-server`, projected SA tokens, controller manager on). Agents issue SVIDs; datasvc healthy with SPIFFE.
- Edge onboarding key now auto-generated/seeded via secret-generator job (and settable via values); core picks it up from `serviceradar-secrets`.
- Core connects to CNPG using `spire` user/DB with CNPG CA mounted; the device metrics CAGG SQL is now split into three single-hypertable CAGGs (`device_metrics_summary_cpu|disk|memory`) plus a joining view so Timescale 2.24 accepts it. Need to roll core with the updated migration bundle to clear the CrashLoop.
- Flowgger still crashlooping due to OpenSSL 3.2 dependency mismatch in the image.
- `db-event-writer` is now healthy and processing messages.
- Agent uses `hostNetwork`; set `dnsPolicy: ClusterFirstWithHostNet` so cluster DNS resolves KV/Core endpoints when pulling config.
- DB event writer now mounts the `cnpg-ca` secret and points its CNPG TLS CA file to `Values.cnpg.caFile` (defaults to `/etc/serviceradar/cnpg/ca.crt`) so SPIFFE Postgres connections can verify the CNPG server cert.
- Added a post-install/upgrade hook job to reseed the db-event-writer KV entry from the charted template using the KV certs, so the CNPG CA path in KV is corrected without manual edits.
