# Change: Fix sysmon-vm macOS service startup after pkg installation

## Why
The sysmon-vm macOS `.pkg` installer drops the binary, config, and LaunchDaemon plist into their correct locations, but the service never starts automatically after installation. Unlike Linux packages that auto-start via systemd triggers, macOS `.pkg` installers require explicit postinstall scripts to bootstrap LaunchDaemons with `launchctl`. The current packaging workflow is missing this critical step.

Additionally, after mTLS onboarding (via `--mtls-bootstrap-only`), the service needs to be restarted to pick up the new configuration, but this was not automated.

## Root Cause
1. **Missing postinstall script**: The `package-host-macos.sh` script creates the `.pkg` with `pkgbuild --root ...` but does not include a `--scripts` directory with postinstall hooks.
2. **No launchctl bootstrap**: Without a postinstall script, the plist at `/Library/LaunchDaemons/com.serviceradar.sysmonvm.plist` is installed but never loaded into launchd.
3. **Missing log directory**: The plist references `/var/log/serviceradar/` for stdout/stderr, but this directory may not exist, causing launchd to fail silently if it cannot open log files.
4. **No service restart after mTLS onboarding**: When users run the mTLS bootstrap command with `--mtls-bootstrap-only`, the config is written but the running service is not restarted to apply the new configuration.

## What Changes
- Add a `scripts/` directory under `packaging/sysmonvm_host/` containing:
  - `postinstall` script that creates log directory, bootstraps, enables, and starts the LaunchDaemon
  - `preinstall` script that gracefully stops any existing service before upgrade
- Update `package-host-macos.sh` to pass `--scripts "${SCRIPTS_DIR}"` to `pkgbuild`
- Update the Bazel BUILD file to include the scripts directory in the packaging workflow
- Update `cmd/checkers/sysmon-vm/main.go` to automatically restart the launchd service after mTLS bootstrap

## Implementation Status: COMPLETE

### Phase 1: Package Scripts (DONE)
Created `packaging/sysmonvm_host/scripts/postinstall` and `preinstall`:
- Creates `/var/log/serviceradar/` directory
- Validates binary, config, and plist exist
- Stops existing service gracefully
- Bootstraps, enables, and starts the LaunchDaemon

### Phase 2: Packaging Script Update (DONE)
Modified `scripts/sysmonvm/package-host-macos.sh`:
- Added `PKG_SCRIPTS_DIR` variable
- Added validation for preinstall/postinstall scripts
- Updated `pkgbuild` to include `--scripts "${PKG_SCRIPTS_DIR}"`

### Phase 3: Bazel Build Update (DONE)
Modified `packaging/sysmonvm_host/BUILD.bazel`:
- Added `pkg_scripts` filegroup
- Updated `sysmonvm_host_pkg` genrule to depend on scripts

### Phase 4: Auto-Restart After mTLS Onboarding (DONE)
Modified `cmd/checkers/sysmon-vm/main.go`:
- Added `restartLaunchdService()` function that calls `launchctl kickstart -k system/com.serviceradar.sysmonvm`
- Called automatically after `--mtls-bootstrap-only` writes the config
- Gracefully handles non-root execution with helpful error message

## User Experience After Fix

### Fresh Install
```bash
# Install the package
sudo installer -pkg serviceradar-sysmonvm-host-macos.pkg -target /

# Service starts automatically - verify with:
sudo launchctl list | grep sysmonvm
ps aux | grep serviceradar-sysmon-vm
```

### mTLS Onboarding
```bash
# Run onboarding (service restarts automatically)
sudo /usr/local/libexec/serviceradar/serviceradar-sysmon-vm \
  --mtls --mtls-bootstrap-only \
  --token "edgepkg-v1:..." \
  --host http://192.168.2.134:8090

# Output now includes:
# 2025/12/02 21:25:08 mTLS bundle installed to /etc/serviceradar/certs
# 2025/12/02 21:25:08 persisted mTLS config to /usr/local/etc/serviceradar/sysmon-vm.json
# 2025/12/02 21:25:08 restarting launchd service system/com.serviceradar.sysmonvm to apply new configuration...
# 2025/12/02 21:25:08 service restart initiated successfully
# 2025/12/02 21:25:08 mTLS bootstrap-only mode enabled; exiting after writing config
```

### Manual Service Control
```bash
# Stop service
sudo launchctl stop system/com.serviceradar.sysmonvm

# Start service
sudo launchctl start system/com.serviceradar.sysmonvm

# Restart service
sudo launchctl kickstart -k system/com.serviceradar.sysmonvm

# Check status
sudo launchctl list | grep sysmonvm
```

## Impact
- Affected specs: edge-onboarding, sysmon-telemetry
- Affected code:
  - `packaging/sysmonvm_host/scripts/postinstall` (new)
  - `packaging/sysmonvm_host/scripts/preinstall` (new)
  - `packaging/sysmonvm_host/BUILD.bazel`
  - `scripts/sysmonvm/package-host-macos.sh`
  - `cmd/checkers/sysmon-vm/main.go`
