# Change: Fix sysmon-vm macOS service startup after pkg installation

## Status: IMPLEMENTED (2025-12-02)

## Why
The sysmon-vm macOS `.pkg` installer drops the binary, config, and LaunchDaemon plist into their correct locations, but the service never starts automatically after installation. Unlike Linux packages that auto-start via systemd triggers, macOS `.pkg` installers require explicit postinstall scripts to bootstrap LaunchDaemons with `launchctl`. The current packaging workflow was missing this critical step.

Additionally, after mTLS onboarding (via `--mtls-bootstrap-only`), the service needed to be restarted to pick up the new configuration, but this was not automated.

## Root Cause
1. **Missing postinstall script**: The `package-host-macos.sh` script created the `.pkg` with `pkgbuild --root ...` but did not include a `--scripts` directory with postinstall hooks.
2. **No launchctl bootstrap**: Without a postinstall script, the plist at `/Library/LaunchDaemons/com.serviceradar.sysmonvm.plist` was installed but never loaded into launchd.
3. **Missing log directory**: The plist references `/var/log/serviceradar/` for stdout/stderr, but this directory may not exist, causing launchd to fail silently if it cannot open log files.
4. **No service restart after mTLS onboarding**: When users ran the mTLS bootstrap command with `--mtls-bootstrap-only`, the config was written but the running service was not restarted to apply the new configuration.

## What Changed

### 1. Package Installer Scripts
Created `packaging/sysmonvm_host/scripts/postinstall`:
- Creates `/var/log/serviceradar/` directory if missing
- Validates binary, config, and plist exist before proceeding
- Stops any existing service gracefully with `launchctl bootout`
- Loads new plist with `launchctl bootstrap system`
- Enables service for auto-start with `launchctl enable`
- Starts service immediately with `launchctl kickstart -k`

Created `packaging/sysmonvm_host/scripts/preinstall`:
- Gracefully stops existing service before upgrade (if running)
- Ensures clean upgrade path

### 2. Packaging Script Update
Modified `scripts/sysmonvm/package-host-macos.sh`:
- Added `PKG_SCRIPTS_DIR="${REPO_ROOT}/packaging/sysmonvm_host/scripts"` variable
- Added validation loop to ensure preinstall/postinstall scripts exist and are executable
- Updated `pkgbuild` invocation to include `--scripts "${PKG_SCRIPTS_DIR}"`
- Updated success message to indicate scripts are included

### 3. Bazel Build Update
Modified `packaging/sysmonvm_host/BUILD.bazel`:
- Added `pkg_scripts` filegroup to track scripts directory
- Updated `sysmonvm_host_pkg` genrule srcs to depend on `:pkg_scripts`

### 4. Auto-Restart After mTLS Onboarding
Modified `cmd/checkers/sysmon-vm/main.go`:
- Added imports: `os/exec`, `runtime`
- Added constant: `launchdServiceTarget = "system/com.serviceradar.sysmonvm"`
- Added `restartLaunchdService()` function:
  - Only runs on darwin (macOS)
  - Checks for root privileges (euid == 0)
  - Calls `launchctl kickstart -k system/com.serviceradar.sysmonvm`
  - Logs helpful message if restart fails (e.g., not running as root)
- Called automatically after `--mtls-bootstrap-only` writes the config

## Files Changed
| File | Change Type |
|------|-------------|
| `packaging/sysmonvm_host/scripts/postinstall` | New |
| `packaging/sysmonvm_host/scripts/preinstall` | New |
| `packaging/sysmonvm_host/BUILD.bazel` | Modified |
| `scripts/sysmonvm/package-host-macos.sh` | Modified |
| `cmd/checkers/sysmon-vm/main.go` | Modified |

## Build & Test

### Build the package
```bash
bazel build --config=darwin_pkg //packaging/sysmonvm_host:sysmonvm_host_pkg
```

Build output confirms scripts are included:
```
pkgbuild: Adding top-level preinstall script
pkgbuild: Adding top-level postinstall script
pkgbuild: Wrote package to .../serviceradar-sysmonvm-host-macos.pkg
Wrote installer package (with pre/postinstall scripts) to ...
```

### Fresh Install
```bash
# Install the package
sudo installer -pkg /tmp/serviceradar-sysmonvm-host-macos.pkg -target /

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

# View logs
tail -f /var/log/serviceradar/sysmon-vm.log
tail -f /var/log/serviceradar/sysmon-vm.err.log
```

## Impact
- Affected specs: edge-onboarding, sysmon-telemetry
- Affected components: sysmon-vm macOS packaging, sysmon-vm binary
