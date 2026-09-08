## ADDED Requirements

### Requirement: SNMP checker config is discoverable in Configuration Management
ServiceRadar MUST surface the globally-scoped `snmp-checker` configuration in Settings → Configuration Management so an admin can view and update SNMP checker settings without editing KV directly.

#### Scenario: Admin finds SNMP checker in the navigation tree
- **GIVEN** an authenticated admin user
- **WHEN** the user opens Settings → Configuration Management
- **THEN** the UI SHALL present “SNMP Checker” as a configurable global service (backed by `config/snmp-checker.json`)

### Requirement: Mapper discovery jobs have a typed UI editor
ServiceRadar MUST provide a typed UI for configuring mapper discovery jobs (e.g. scheduled LAN discovery) so operators do not need to hand-author JSON for common fields such as seeds and SNMP credentials.

#### Scenario: Admin configures a scheduled discovery job without JSON
- **GIVEN** an authenticated admin user
- **WHEN** the user edits mapper scheduled job settings in the UI (e.g. name, interval, enabled, seeds, discovery type, credentials)
- **THEN** the UI SHALL persist those changes via the Core admin config API for `mapper`
- **AND** the UI SHALL NOT require the user to paste raw JSON to set those common fields

### Requirement: Poller checks use a service-type-aware editor
ServiceRadar MUST provide a poller check editor that guides users via a “check kind” dropdown and renders appropriate inputs per kind, rather than requiring users to manually assemble `service_type` + `service_name` tuples or paste JSON into `details`.

#### Scenario: Sysmon selection maps to gRPC fields
- **GIVEN** an authenticated admin user editing a poller’s agent checks
- **WHEN** the user selects “Sysmon” as the check kind
- **THEN** the UI SHALL persist `service_type="grpc"` and `service_name="sysmon"` for that check
- **AND** the UI SHALL render a friendly field for the gRPC target address (the `details` value)

#### Scenario: Mapper discovery status selection renders mapper-specific fields
- **GIVEN** an authenticated admin user editing a poller’s agent checks
- **WHEN** the user selects “Mapper discovery status” as the check kind
- **THEN** the UI SHALL persist `service_type="mapper_discovery"` for that check
- **AND** the UI SHALL render mapper-discovery-specific inputs (for example `include_raw_data`) rather than requiring raw JSON in `details`

### Requirement: Secrets are redacted and preserved for UI edits
ServiceRadar MUST redact secret configuration values returned to the browser and MUST preserve prior values when the browser submits redacted placeholders.

#### Scenario: SNMP credential values are not disclosed to the browser
- **GIVEN** an authenticated admin user reads mapper or snmp-checker config via Configuration Management
- **WHEN** the response contains secret fields (e.g. SNMP community strings, auth passwords, API keys)
- **THEN** Core SHALL redact those values in the response
- **AND** when the user saves changes without modifying the secret field, Core SHALL preserve the previous secret value
