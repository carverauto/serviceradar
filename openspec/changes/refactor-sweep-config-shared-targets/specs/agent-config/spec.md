## ADDED Requirements

### Requirement: Capability-Gated Sweep Config Format

The control plane SHALL choose the sweep config format per agent from that
agent's persisted capabilities. It SHALL emit `shared-targets/v1` only to
agents whose capabilities include `sweep-config-shared-targets:v1`, and SHALL
emit the legacy format to every other agent. Compiled sweep configs SHALL be
cached per format, so an agent never receives a cached document in a format
other than the one selected for it.

#### Scenario: Legacy agent never receives the shared-targets format
- **GIVEN** an agent whose persisted capabilities do not include
  `sweep-config-shared-targets:v1`
- **WHEN** it requests configuration
- **THEN** its sweep section SHALL have no `format` field
- **AND** its groups SHALL embed `device_targets` as before

#### Scenario: Upgraded agent receives the shared-targets format
- **GIVEN** an agent whose persisted capabilities include
  `sweep-config-shared-targets:v1`
- **WHEN** it requests configuration
- **THEN** its sweep section SHALL have `format` equal to
  `shared-targets/v1`

#### Scenario: Mixed fleet in one partition
- **GIVEN** two agents in the same partition, eligible for the same sweep
  groups
- **AND** only one of them advertises `sweep-config-shared-targets:v1`
- **WHEN** both request configuration
- **THEN** each SHALL receive its own format
- **AND** neither SHALL receive a cached document compiled for the other's
  format

#### Scenario: Capability change switches format without stale cache
- **GIVEN** an agent that received the legacy format
- **WHEN** it is upgraded, advertises `sweep-config-shared-targets:v1`, and
  requests configuration again
- **THEN** it SHALL receive the `shared-targets/v1` format
- **AND** the config version SHALL differ from its previous one, so the new
  config is applied rather than reported as not modified
