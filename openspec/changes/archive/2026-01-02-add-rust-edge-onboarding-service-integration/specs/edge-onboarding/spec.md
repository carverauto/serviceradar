# Spec Delta: edge-onboarding

## ADDED Requirements

### Requirement: Bootstrap-only mode for service integration

The Rust edge-onboarding crate SHALL support a bootstrap-only mode that installs credentials, writes configuration to system paths, restarts the system service, and exits without starting the application server.

#### Scenario: Bootstrap-only mode on Linux with systemd

- **GIVEN** the operator runs `serviceradar-sysmon-checker --mtls --token <token> --host <core> --mtls-bootstrap-only`
- **WHEN** mTLS bootstrap completes successfully
- **THEN** the crate SHALL write certificates to `/etc/serviceradar/certs/`
- **AND** the crate SHALL write configuration to `/etc/serviceradar/checkers/sysmon.json`
- **AND** the crate SHALL execute `systemctl restart serviceradar-sysmon-checker`
- **AND** the process SHALL exit with code 0 without starting the gRPC server

#### Scenario: Bootstrap-only mode on macOS with launchd

- **GIVEN** the operator runs the checker with `--mtls-bootstrap-only` on macOS
- **WHEN** mTLS bootstrap completes successfully
- **THEN** the crate SHALL write certificates to the configured cert directory
- **AND** the crate SHALL write configuration to the appropriate macOS path
- **AND** the crate SHALL execute `launchctl kickstart -k system/<service>`
- **AND** the process SHALL exit with code 0 without starting the gRPC server

#### Scenario: Bootstrap-only mode without root privileges

- **GIVEN** the operator runs bootstrap-only mode without root/sudo privileges
- **WHEN** the service restart step is reached
- **THEN** the crate SHALL log a warning that service restart may fail
- **AND** the crate SHALL attempt the restart and report the outcome
- **AND** the crate SHALL exit with non-zero code if the service restart fails

### Requirement: System path management

The Rust edge-onboarding crate SHALL provide functions to manage standard system paths for systemd-integrated deployments.

#### Scenario: Directory creation with proper permissions

- **WHEN** `ensure_directories()` is called with service name "sysmon"
- **THEN** the crate SHALL create `/etc/serviceradar/checkers/` if it does not exist
- **AND** the crate SHALL create `/etc/serviceradar/certs/` if it does not exist
- **AND** the crate SHALL create `/var/log/serviceradar/` if it does not exist
- **AND** directories SHALL be created with mode 0755

#### Scenario: Certificate installation to system paths

- **WHEN** bootstrap-only mode installs certificates
- **THEN** private keys SHALL be written with mode 0600
- **AND** certificates and CA files SHALL be written with mode 0644
- **AND** files SHALL be owned by root or the configured service user

### Requirement: Platform-aware service restart

The Rust edge-onboarding crate SHALL provide a platform-aware function to restart system services.

#### Scenario: Service restart on Linux

- **WHEN** `restart_service("serviceradar-sysmon-checker")` is called on Linux
- **THEN** the crate SHALL execute `systemctl restart serviceradar-sysmon-checker`
- **AND** return success if the command exits with code 0
- **AND** return an error with the exit code if the command fails

#### Scenario: Service restart on macOS

- **WHEN** `restart_service("com.serviceradar.sysmon")` is called on macOS
- **THEN** the crate SHALL execute `launchctl kickstart -k system/com.serviceradar.sysmon`
- **AND** return success if the command exits with code 0
- **AND** return an error with the exit code if the command fails

#### Scenario: Service restart on unsupported platform

- **WHEN** `restart_service()` is called on an unsupported platform (e.g., Windows)
- **THEN** the crate SHALL return an `UnsupportedPlatform` error

## MODIFIED Requirements

### Requirement: mTLS bootstrap configuration (MODIFIED)

The `MtlsBootstrapConfig` struct SHALL accept additional fields for bootstrap-only mode and system path configuration.

#### Scenario: Extended configuration for bootstrap-only

- **GIVEN** a `MtlsBootstrapConfig` with `bootstrap_only: true`
- **WHEN** `mtls_bootstrap()` or `mtls_bootstrap_and_activate()` is called
- **THEN** the crate SHALL use system paths (`/etc/serviceradar/...`) instead of runtime paths (`/var/lib/serviceradar/...`)
- **AND** the crate SHALL restart the system service after writing configuration
- **AND** the crate SHALL return the `OnboardingResult` without starting the application
