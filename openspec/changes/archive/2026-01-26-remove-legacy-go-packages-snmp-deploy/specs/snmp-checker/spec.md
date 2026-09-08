## ADDED Requirements
### Requirement: SNMP checker is embedded in serviceradar-agent only
The system SHALL ship SNMP checking capabilities exclusively as an embedded library within `serviceradar-agent` and SHALL NOT build, publish, or deploy a standalone SNMP checker service.

#### Scenario: Build and release artifacts exclude standalone SNMP checker
- **WHEN** release artifacts are built (Bazel targets, Docker images)
- **THEN** no standalone SNMP checker image or binary is produced
- **AND** SNMP functionality remains available via `serviceradar-agent`

#### Scenario: Deployment manifests exclude standalone SNMP checker
- **WHEN** Docker Compose or Helm manifests are rendered
- **THEN** no standalone SNMP checker service, deployment, or chart entry is present
- **AND** SNMP configuration continues to apply to `serviceradar-agent`
