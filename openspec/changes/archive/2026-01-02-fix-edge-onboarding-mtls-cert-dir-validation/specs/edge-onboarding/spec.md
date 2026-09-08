## ADDED Requirements

### Requirement: mTLS CA file access is confined to an operator-configured directory
When issuing an edge onboarding package in mTLS mode, Core SHALL only read the CA certificate and private key from an operator-configured base directory (default: `/etc/serviceradar/certs`) and SHALL reject requests that attempt to reference paths outside that directory.

#### Scenario: Reject user-controlled CA path escape attempt
- **GIVEN** edge onboarding is enabled
- **WHEN** an admin issues an mTLS edge package with `metadata_json` that sets `ca_cert_path` (or `ca_key_path`) to a path outside the configured base directory
- **THEN** Core SHALL reject the request as invalid
- **AND** Core SHALL NOT attempt to read the referenced CA cert/key paths

#### Scenario: Allow default CA directory
- **GIVEN** edge onboarding is enabled
- **WHEN** an admin issues an mTLS edge package without overriding CA certificate/key paths
- **THEN** Core SHALL read CA material from the configured base directory and mint the mTLS bundle
