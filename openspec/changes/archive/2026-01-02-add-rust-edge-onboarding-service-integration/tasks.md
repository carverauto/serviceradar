# Tasks: Add service integration to Rust edge-onboarding crate

## 1. Rust edge-onboarding crate: Service module

- [ ] 1.1 Create `rust/edge-onboarding/src/service.rs` module with platform detection
- [ ] 1.2 Implement Linux systemd restart: `systemctl restart <service>`
- [ ] 1.3 Implement macOS launchd restart: `launchctl kickstart -k system/<service>`
- [ ] 1.4 Add privilege check (warn if not root/sudo for service restart)
- [ ] 1.5 Export `restart_service()` function from crate

## 2. Rust edge-onboarding crate: Path configuration

- [ ] 2.1 Create `rust/edge-onboarding/src/paths.rs` module for systemd-aware paths
- [ ] 2.2 Define standard paths: `/etc/serviceradar/checkers/`, `/etc/serviceradar/certs/`, `/var/log/serviceradar/`
- [ ] 2.3 Add `ensure_directories()` function to create required dirs with proper permissions
- [ ] 2.4 Add `symlink_config()` or `copy_config()` to place config in systemd-expected location

## 3. Rust edge-onboarding crate: Bootstrap-only mode

- [ ] 3.1 Add `bootstrap_only: bool` field to `MtlsBootstrapConfig`
- [ ] 3.2 Modify `mtls_bootstrap()` to accept bootstrap-only mode
- [ ] 3.3 Create `mtls_bootstrap_only()` function that:
  - Performs mTLS bootstrap
  - Writes config to `/etc/serviceradar/checkers/<service>.json`
  - Installs certs to `/etc/serviceradar/certs/`
  - Creates log directory
  - Restarts systemd/launchd service
  - Returns without starting gRPC server
- [ ] 3.4 Add unit tests for bootstrap-only flow (mock service restart)

## 4. Sysmon checker: CLI integration

- [ ] 4.1 Add `--mtls-bootstrap-only` flag to clap argument parser
- [ ] 4.2 Wire flag to edge-onboarding crate's bootstrap-only mode
- [ ] 4.3 Exit after bootstrap completes when flag is set
- [ ] 4.4 Update help text to document bootstrap-only workflow

## 5. Systemd service file updates

- [ ] 5.1 Update `packaging/sysmon/systemd/serviceradar-sysmon-checker.service`:
  - Support config path override via environment variable
  - Use `StandardOutput=journal` instead of file (simpler, avoids missing dir issues)
  - Consider `DynamicUser=yes` or document `serviceradar` user requirement
- [ ] 5.2 Add `EnvironmentFile=-/etc/serviceradar/sysmon.env` for overrides

## 6. RPM/DEB postinst script updates

- [ ] 6.1 Update `packaging/sysmon/scripts/postinstall.sh`:
  - Create `/var/log/serviceradar/` directory
  - Create `/etc/serviceradar/checkers/` directory
  - Create `/etc/serviceradar/certs/` directory
  - Create `serviceradar` system user/group if not exists
  - Set ownership on directories
- [ ] 6.2 Test RPM install on fresh Alma 9 system
- [ ] 6.3 Test DEB install on fresh Ubuntu system

## 7. Documentation and testing

- [ ] 7.1 Update `rust/edge-onboarding/README.md` with bootstrap-only usage
- [ ] 7.2 Add integration test: bootstrap-only mode writes correct files
- [ ] 7.3 Document the complete workflow in `docs/docs/edge-onboarding.md`

## 8. (Future) Poller auto-configuration

- [ ] 8.1 Design: How should poller config be updated in KV when checker package is created?
- [ ] 8.2 Implement: Update `pkg/core/edge_onboarding.go` to modify poller targets
- [ ] 8.3 Test: Create checker package via UI, verify poller config updated

## Dependencies
- Tasks 1-3 can be done in parallel
- Task 4 depends on tasks 1-3
- Tasks 5-6 can be done in parallel with tasks 1-4
- Task 7 depends on all above
- Task 8 is independent future work
