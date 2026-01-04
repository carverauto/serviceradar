# Design: Rust edge-onboarding service integration

## Overview

This design extends the `rust/edge-onboarding` crate to support "bootstrap-only" mode, enabling zero-touch deployment where:
1. Operator creates edge package in UI
2. Operator runs bootstrap command on edge host
3. Bootstrap installs certs, writes config to systemd-expected paths, restarts service, exits
4. Service runs under systemd with proper config

## Current State

### Go sysmon-osx approach
```go
// cmd/checkers/sysmon-osx/main.go
mtlsBootstrapOnly := flag.Bool("mtls-bootstrap-only", false,
    "Run mTLS bootstrap, persist config, then exit without starting the service")

if *mtlsBootstrapOnly {
    log.Printf("mTLS bootstrap-only mode enabled; exiting after writing config")
    if err := restartLaunchdService(ctx); err != nil {
        log.Printf("note: could not restart launchd service: %v", err)
    }
    return nil
}
```

### Current Rust sysmon approach
- `--mtls` flag performs bootstrap then starts server in foreground
- Config written to `/var/lib/serviceradar/checker/config/checker.json`
- Systemd expects config at `/etc/serviceradar/checkers/sysmon.json`
- Mismatch causes service startup failure

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    edge-onboarding crate                        │
├─────────────────────────────────────────────────────────────────┤
│  lib.rs                                                         │
│    ├── mtls_bootstrap()        # existing: bootstrap + return   │
│    └── mtls_bootstrap_only()   # NEW: bootstrap + restart svc   │
│                                                                 │
│  service.rs (NEW)                                               │
│    ├── restart_service(name)   # platform-aware restart         │
│    ├── restart_systemd(name)   # Linux: systemctl restart       │
│    └── restart_launchd(name)   # macOS: launchctl kickstart     │
│                                                                 │
│  paths.rs (NEW)                                                 │
│    ├── SystemPaths             # /etc/serviceradar/... paths    │
│    ├── ensure_directories()    # create dirs with perms         │
│    └── install_config()        # write config to system path    │
└─────────────────────────────────────────────────────────────────┘
```

## Path Strategy

### Standard system paths (used in bootstrap-only mode)
```
/etc/serviceradar/
├── checkers/
│   └── sysmon.json           # checker config (systemd expects this)
├── certs/
│   ├── sysmon.pem            # client certificate
│   ├── sysmon-key.pem        # client private key
│   └── root.pem              # CA certificate
└── sysmon.env                # optional environment overrides

/var/log/serviceradar/
└── sysmon-checker.log        # service logs (if not using journal)
```

### Runtime paths (used in non-bootstrap mode, containers)
```
/var/lib/serviceradar/checker/
├── config/
│   └── checker.json
└── certs/
    └── ...
```

## Bootstrap-Only Flow

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Parse CLI args  │────▶│  Download mTLS   │────▶│  Install certs   │
│  --mtls          │     │  bundle from     │     │  to /etc/...     │
│  --token         │     │  Core API        │     │  /certs/         │
│  --host          │     │                  │     │                  │
│  --bootstrap-only│     │                  │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                                           │
                                                           ▼
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Exit(0)         │◀────│  Restart systemd │◀────│  Write config    │
│                  │     │  service         │     │  to /etc/...     │
│                  │     │                  │     │  /checkers/      │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

## API Design

### MtlsBootstrapConfig extension
```rust
pub struct MtlsBootstrapConfig {
    pub token: String,
    pub host: Option<String>,
    pub bundle_path: Option<String>,
    pub cert_dir: Option<String>,
    pub service_name: Option<String>,
    // NEW fields
    pub bootstrap_only: bool,           // Exit after bootstrap
    pub use_system_paths: bool,         // Use /etc/... instead of /var/lib/...
    pub systemd_service: Option<String>, // Service name for restart
}
```

### New function
```rust
/// Perform mTLS bootstrap and restart system service.
///
/// This is the "bootstrap-only" mode for production deployments:
/// 1. Downloads mTLS bundle from Core API
/// 2. Installs certificates to /etc/serviceradar/certs/
/// 3. Writes config to /etc/serviceradar/checkers/<service>.json
/// 4. Restarts the systemd/launchd service
/// 5. Returns (does not start gRPC server)
pub fn mtls_bootstrap_and_activate(cfg: &MtlsBootstrapConfig) -> Result<OnboardingResult>
```

## Service Restart Implementation

```rust
// service.rs

use std::process::Command;

pub fn restart_service(service_name: &str) -> Result<()> {
    #[cfg(target_os = "linux")]
    return restart_systemd(service_name);

    #[cfg(target_os = "macos")]
    return restart_launchd(service_name);

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    return Err(Error::UnsupportedPlatform);
}

#[cfg(target_os = "linux")]
fn restart_systemd(service_name: &str) -> Result<()> {
    // Check if running as root
    if !nix::unistd::geteuid().is_root() {
        tracing::warn!("Not running as root; service restart may fail");
    }

    let status = Command::new("systemctl")
        .args(["restart", service_name])
        .status()
        .map_err(|e| Error::ServiceRestart {
            service: service_name.to_string(),
            source: e
        })?;

    if !status.success() {
        return Err(Error::ServiceRestartFailed {
            service: service_name.to_string(),
            exit_code: status.code(),
        });
    }

    tracing::info!(service = service_name, "Service restarted successfully");
    Ok(())
}

#[cfg(target_os = "macos")]
fn restart_launchd(service_name: &str) -> Result<()> {
    let target = format!("system/{}", service_name);
    let status = Command::new("launchctl")
        .args(["kickstart", "-k", &target])
        .status()
        .map_err(|e| Error::ServiceRestart {
            service: service_name.to_string(),
            source: e
        })?;

    if !status.success() {
        return Err(Error::ServiceRestartFailed {
            service: service_name.to_string(),
            exit_code: status.code(),
        });
    }

    Ok(())
}
```

## Systemd Service File Update

```ini
[Unit]
Description=ServiceRadar SysMon metrics collector
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/serviceradar-sysmon-checker --config ${CONFIG_PATH}
Environment="CONFIG_PATH=/etc/serviceradar/checkers/sysmon.json"
EnvironmentFile=-/etc/serviceradar/sysmon.env
Restart=on-failure
# Use DynamicUser for security, or require serviceradar user
DynamicUser=yes
StateDirectory=serviceradar
LogsDirectory=serviceradar

# Use journal instead of file logging to avoid directory issues
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

## Trade-offs

### Option A: Symlink approach
- Bootstrap writes to `/var/lib/...`, creates symlink to `/etc/...`
- Pro: Single source of truth
- Con: More complex, symlinks can be confusing

### Option B: Direct write to /etc (CHOSEN)
- Bootstrap writes directly to `/etc/serviceradar/...`
- Pro: Simple, matches systemd conventions
- Con: Different from container runtime paths

### Option C: Environment override
- Systemd uses `CONFIG_PATH` env var, bootstrap sets it
- Pro: Flexible
- Con: Requires env file management

**Decision**: Option B with fallback to Option C. Bootstrap-only mode writes to `/etc/...`. Container/runtime mode uses `/var/lib/...`. Systemd service supports `CONFIG_PATH` override for flexibility.

## Security Considerations

1. **Privilege escalation**: Service restart requires root. Document that bootstrap-only should run with `sudo`.
2. **File permissions**: Certs written with 0600 (keys) and 0644 (certs). Config written with 0644.
3. **User isolation**: Consider `DynamicUser=yes` in systemd or dedicated `serviceradar` user.

## Testing Strategy

1. **Unit tests**: Mock service restart, verify correct paths used
2. **Integration test**: Docker container with systemd, run bootstrap-only, verify service restarts
3. **Manual test**: Fresh Alma 9 VM, install RPM, run bootstrap-only, verify service running
