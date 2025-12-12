## MODIFIED Requirements

### Requirement: Sysmon checker packages default to mTLS on bare metal
Edge onboarding for sysmon checkers SHALL default to issuing mTLS packages unless the operator explicitly requests SPIFFE/SPIRE.

#### Scenario: Admin issues sysmon checker package without security_mode
- **GIVEN** edge onboarding is enabled
- **WHEN** an admin creates an edge package for a `checker` with `checker_kind: "sysmon"` and omits `security_mode`
- **THEN** Core SHALL treat the package as `security_mode: "mtls"` and include an mTLS bundle in the deliver response
- **AND** the generated checker config for sysmon SHALL reference the standard bare‑metal cert directory.

### Requirement: Sysmon mTLS onboarding is non‑interactive and persists state
The sysmon edge onboarding flow SHALL install configuration and mTLS credentials to standard bare‑metal paths and restart the service without user interaction.

#### Scenario: Edge host bootstraps sysmon in mTLS mode
- **WHEN** an operator runs `serviceradar-sysmon-checker --mtls --token <edgepkg> --host <core> --mtls-bootstrap-only` on a bare‑metal Linux host
- **THEN** sysmon SHALL download the package from `/api/admin/edge-packages/{id}/download?format=json`
- **AND** it SHALL write certificates to `/var/lib/serviceradar/sysmon/certs` (or the resolved bare‑metal cert dir)
- **AND** it SHALL write config to `/var/lib/serviceradar/sysmon/config/checker.json`, copy it to `/etc/serviceradar/checkers/sysmon.json`, restart the systemd unit, and exit `0`.

## ADDED Requirements

### Requirement: Edge package delivery errors are actionable
Core SHALL log and return actionable errors for edge package delivery failures, rather than an undifferentiated 502.

#### Scenario: Delivery fails due to decryption error
- **GIVEN** a package ciphertext cannot be decrypted (e.g., due to key rotation)
- **WHEN** an edge host requests `/api/admin/edge-packages/{id}/download`
- **THEN** Core SHALL return `500` with a message indicating decryption failure and next steps (reissue token)
- **AND** Core logs SHALL include the underlying error and package id.

