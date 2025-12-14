# kv-configuration Spec Delta (fix-compose-upgrade-config-clobbering)

## ADDED Requirements
### Requirement: Non-Destructive Compose Upgrades
Docker Compose upgrades SHALL preserve user-managed configuration state (both persistent config artifacts and KV-backed configuration). Bootstrap jobs used by Compose (e.g., config-updater and KV seeders) MUST NOT overwrite existing non-empty configuration values during routine upgrades.

#### Scenario: Upgrade preserves sysmon endpoint
- **GIVEN** a running Compose stack with a configured sysmon endpoint in the poller configuration
- **WHEN** the stack is upgraded (images updated and containers recreated)
- **THEN** the sysmon endpoint remains configured after the upgrade
- **AND** system metrics continue to populate without requiring manual reconfiguration

#### Scenario: Bootstrap does not write empty overrides
- **GIVEN** a running Compose stack with non-empty configuration values stored in KV and/or persisted config artifacts
- **AND** a bootstrap script is re-run during upgrade
- **WHEN** an optional/override env var is unset or empty
- **THEN** the bootstrap script DOES NOT write empty values into configuration files or KV

