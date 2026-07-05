# wasm-plugin-system — deltas

## ADDED Requirements

### Requirement: Credential-rule materialization feeds plugin inputs
The system SHALL materialize enabled credential rules into `serviceradar.plugin_inputs.v1` assignments for matching plugins and agents (SRQL-scoped targets, credential grants, per-target connection parameters such as host), and plugins SHALL accept both a flat config object and the plugin-inputs envelope, deriving per-target parameters from the envelope.

#### Scenario: Rule to envelope to plugin
- **GIVEN** an enabled camera credential rule scoped to an agent
- **WHEN** materialization reconciles
- **THEN** the target plugin SHALL receive a plugin-inputs envelope with SRQL-resolved targets and a credential grant
- **AND** the plugin SHALL derive per-target host/connection parameters from the envelope without requiring inline config

#### Scenario: Materialization regression coverage
- **GIVEN** the provider profiles (proxmox, unifi-protect, axis)
- **WHEN** materializer or profile code changes
- **THEN** regression tests SHALL pin rule → materialized inputs → successful plugin config decode for each profile

### Requirement: Credential push-down resolves live with in-memory handling by default
Plugin credential grants SHALL default to agent-side live resolution — material fetched via the gateway broker at execution time and held only in memory while the plugin runs. Provider profiles that must resolve at the control plane SHALL declare that exception explicitly, with short-TTL grants, and the exception SHALL be documented in the provider profile.

#### Scenario: Agent-side resolution keeps secrets out of configs
- **GIVEN** a provider profile using agent-side resolution
- **WHEN** agent configuration is generated and pushed
- **THEN** the pushed config SHALL contain a broker grant reference, not resolved secret material
- **AND** the agent SHALL resolve the grant at execution time and hold material only in memory

#### Scenario: Control-plane exceptions are explicit
- **GIVEN** a provider profile that cannot resolve agent-side
- **WHEN** the profile declares `resolution_location: :control_plane`
- **THEN** the declaration SHALL include the documented constraint requiring it
- **AND** grants resolved at the control plane SHALL use short TTLs
