# Change: Add service integration to Rust edge-onboarding crate

## Why
- Currently, running mTLS bootstrap on a Rust-based checker (sysmon) starts the service in the foreground, requiring manual systemd configuration afterward.
- The Go-based `sysmon-osx` has a `--mtls-bootstrap-only` flag that bootstraps credentials, persists config, restarts the system service (launchd), and exits - enabling true zero-touch deployment.
- Rust checkers need the same capability to support production deployments where the service runs under systemd.
- The RPM postinst script should handle directory creation and service setup, but the onboarding crate needs to write configs to paths the systemd service expects.
- Additionally, when creating a checker edge package via the UI, the poller should be automatically configured to poll the new checker.

## What Changes

### 1. Rust edge-onboarding crate enhancements (`rust/edge-onboarding`)
- Add `--mtls-bootstrap-only` / `bootstrap_only` mode that:
  - Performs mTLS bootstrap (download certs, install bundle)
  - Writes config to systemd-expected paths (`/etc/serviceradar/checkers/<service>.json`)
  - Creates required directories (`/var/log/serviceradar/`, cert dirs)
  - Symlinks or copies generated config to expected locations
  - Restarts the systemd service (Linux) or launchd service (macOS)
  - Exits without starting the gRPC server
- Add platform-aware service restart:
  - Linux: `systemctl restart <service>`
  - macOS: `launchctl kickstart -k system/<service>`
- Add configurable paths for systemd integration:
  - Config path: `/etc/serviceradar/checkers/`
  - Cert path: `/etc/serviceradar/certs/`
  - Log path: `/var/log/serviceradar/`

### 2. Sysmon checker updates (`cmd/checkers/sysmon`)
- Add `--mtls-bootstrap-only` CLI flag that delegates to the edge-onboarding crate
- Update systemd service file to use correct config path or support env-based override

### 3. RPM/DEB packaging updates (`packaging/sysmon`)
- postinst script creates `/var/log/serviceradar/` directory
- postinst script creates `serviceradar` user/group if not exists
- postinst script sets proper ownership on cert/config directories

### 4. Core API: Auto-configure poller when creating checker packages (future scope)
- When a checker edge package is created, update the parent poller's config in KV to include the new checker target
- This enables true zero-touch: create package in UI → run bootstrap on edge → poller automatically starts polling

## Impact
- Affected specs: edge-onboarding
- Affected code:
  - Modified: `rust/edge-onboarding/src/lib.rs` (add bootstrap-only mode, service restart)
  - Modified: `cmd/checkers/sysmon/src/main.rs` (add CLI flag)
  - Modified: `packaging/sysmon/systemd/serviceradar-sysmon-checker.service`
  - Modified: `packaging/sysmon/scripts/postinstall.sh`
- New modules in edge-onboarding crate:
  - `service.rs` - Platform-aware service restart logic
  - `paths.rs` - Systemd/launchd path configuration

## Related Changes
- Extends: `integrate-sysmon-edge-onboarding` (adds bootstrap-only mode to existing onboarding)
- Related: `add-mtls-only-edge-onboarding` (mTLS infrastructure this builds on)
