## 1. Sysmon default config
- [x] 1.1 Change `cmd/checkers/sysmon/config/default_template.json` to mTLS defaults matching bare‑metal cert layout.
- [x] 1.2 Change `packaging/sysmon/config/checkers/sysmon.json.example` to mTLS defaults (align with embedded template).
- [ ] 1.3 Verify systemd unit + packaging still seed KV successfully; update any related docs/runbooks.

## 2. Sysmon edge onboarding hardening
- [ ] 2.1 Confirm sysmon mTLS checker template exists in KV seeding for Compose/Helm; add/update template if missing.
- [x] 2.2 Update Core create‑package path to default `checker:sysmon` packages to `security_mode: mtls` when not specified.
- [ ] 2.3 Add Core validation so sysmon checker packages cannot be issued without a valid template or `checker_config_json`.
- [x] 2.4 Improve Core deliver‑package error logging and classification (decrypt failures, DB failures).
- [x] 2.5 Add/extend tests around sysmon mTLS package create/deliver and error cases.
- [x] 2.6 Include optional `checker_endpoint` metadata in checker mTLS cert SANs to support external checker verification by IP/DNS.

## 3. Bare‑metal E2E validation
- [x] 3.1 Build new sysmon RPM/Deb and install on Alma9/RHEL test host.
- [x] 3.2 Issue sysmon mTLS edge package; onboard with `serviceradar-sysmon-checker --mtls --token <token> --host <core> --mtls-bootstrap-only`.
- [x] 3.3 Verify files at `/var/lib/serviceradar/sysmon/{certs,config}` and `/etc/serviceradar/checkers/sysmon.json`, and service restarts cleanly.
- [ ] 3.4 Verify poller/agent can reach sysmon and metrics ingest.
