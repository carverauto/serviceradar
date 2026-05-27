## ADDED Requirements

### Requirement: Visibility sub-config compilation and delivery

The agent configuration pipeline SHALL compile per-device visibility
bindings from enabled
`Serviceradar.Inventory.VisibilityProfile` resources via a
`VisibilityCompiler` that uses the shared `SrqlTargetResolver`. The
compiled output MUST be embedded in
`AgentConfigResponse.visibility_config` (parallel to `sysmon_config`
and `snmp_config`) and MUST be included in the config version hash
used for change detection.

#### Scenario: Profile change invalidates the config hash
- **WHEN** an operator enables, disables, edits, or deletes a
  `VisibilityProfile`
- **THEN** the next compiled `AgentConfigResponse` for every affected
  agent contains an updated `config_version` hash
- **AND** subsequent `GetConfig` calls return the new payload rather
  than a `not_modified` response

#### Scenario: Devices without matching profiles receive no binding
- **WHEN** the compiler runs and a device matches no enabled profile's
  `target_query`
- **THEN** the device's IP does not appear in
  `visibility_config.device_bindings`

### Requirement: Capture interface allowlist carried in agent config

The compiled `visibility_config` SHALL include the agent's
operator-curated capture interface allowlist as
`capture_interfaces`. The list MUST be partition-scoped and MUST be
respected by `netprobe`'s deny-by-default capture posture defined in
`host-network-visibility`.

#### Scenario: Empty allowlist disables capture entirely
- **WHEN** the operator has configured no capture interfaces for an
  agent
- **THEN** `visibility_config.capture_interfaces` is empty
- **AND** the agent forwards an `ApplyConfig` to the sidecar with an
  empty allowlist
- **AND** the sidecar performs no packet capture until the allowlist is
  populated
