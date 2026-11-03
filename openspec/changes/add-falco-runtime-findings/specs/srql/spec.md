## ADDED Requirements

### Requirement: SRQL runtime findings entity
SRQL SHALL provide `in:runtime_findings` (aliases `runtime_finding`, `falco_findings`) that reads current runtime findings from CNPG on installations with and without StarRocks.
It SHALL support filters on `status`, `severity`, `rule`, `priority`, `entity_kind`, `cluster`, `namespace`, `owner_kind`, `owner`, `pod`, `hostname`, `device_uid`, `node_device_uid`, `binding_status`, `attribution`, `tactic`, `technique`, `first_seen`, `last_seen`, `finding_uid`, and `time:` applied to `last_seen`; it SHALL default to `last_seen` descending and SHALL support `stats` counts grouped by rule, namespace, owner and device.

#### Scenario: Active findings for one namespace
- **WHEN** a client runs `in:runtime_findings status:active namespace:shop sort:severity:desc`
- **THEN** SRQL SHALL return only active runtime findings whose subject is in namespace `shop`, ordered by severity

#### Scenario: Findings bound to a device
- **WHEN** a client runs `in:runtime_findings device_uid:"sr:00000000-0000-4000-8000-000000000001"`
- **THEN** SRQL SHALL return findings whose subject is bound to that device

#### Scenario: Unbound findings are queryable
- **WHEN** a client runs `in:runtime_findings binding_status:ambiguous`
- **THEN** SRQL SHALL return findings with an ambiguous binding and their candidate counts

### Requirement: SRQL runtime security occurrences entity
SRQL SHALL provide `in:runtime_security_occurrences` (alias `runtime_occurrences`) that reads the Falco occurrence dataset from StarRocks when it is enabled and from CNPG otherwise, with filters on its typed columns including `finding_uid`, `rule`, `priority`, `hostname`, `device_uid`, `node_device_uid`, `namespace`, `owner`, `pod`, `container_id`, `image`, `process`, `exe`, `user`, `evt_type`, `src_ip`, `dst_ip`, `dst_port`, `tactic`, `technique` and `time:`.
List projections MUST NOT return `raw_payload` unless the query selects it explicitly. The warehouse reader SHALL pass the result-diff parity harness against the CNPG reader before it ships.

#### Scenario: Timeline for one finding
- **WHEN** a client requests hourly occurrence counts from `in:runtime_security_occurrences` for `finding_uid:"22222222-2222-4222-8222-222222222222"` over `time:last_24h`
- **THEN** SRQL SHALL return hourly occurrence counts for that finding from the active backend

#### Scenario: Raw payload is opt-in
- **WHEN** a client lists occurrences without selecting `raw_payload`
- **THEN** the rows SHALL NOT include the raw payload
