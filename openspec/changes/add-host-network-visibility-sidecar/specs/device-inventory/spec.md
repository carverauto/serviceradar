## ADDED Requirements

### Requirement: Passive Fingerprint Evidence on OCSF OS and Metadata

The `Serviceradar.Inventory.Device` Ash resource SHALL accept and
persist a `passive_fingerprint` map under both the OCSF `os` attribute
and the extension `metadata` attribute. The `os.passive_fingerprint`
map MUST carry `family`, `version`, `confidence` (0..1), `source`
(literal `"serviceradar-license-clean"`), and `observed_at`. The
`metadata.passive_fingerprint` map MUST carry protocol-specific
signature payloads keyed by `tcp`, `tls`, and `http`, each with its
own `observed_at`. No new database tables are introduced.

#### Scenario: TCP-only observation populates both OCSF and metadata maps
- **WHEN** a passive-netprobe discovery record carrying a TCP signature
  is ingested for a device
- **THEN** `device.os.passive_fingerprint` is populated with `{family,
  version, confidence, source: "serviceradar-license-clean", observed_at}`
- **AND** `device.metadata.passive_fingerprint.tcp` is populated with
  the p0f signature payload and `observed_at`

#### Scenario: Stored map keys are forward-compatible
- **WHEN** a future signature engine adds a new protocol payload
- **THEN** the device's `metadata.passive_fingerprint` map can hold the
  new key alongside `tcp`, `tls`, `http` without a destructive migration

### Requirement: DPI Protocol Map on Device Metadata

The `Serviceradar.Inventory.Device` Ash resource SHALL accept and
persist a `metadata.dpi` map containing per-protocol classification
evidence. Each entry MUST carry `count`, `confidence`, and
`last_observed_at`. The map MUST NOT contain payload material (no URIs,
no DNS query names, no request or response bodies).

#### Scenario: TLS classification updates the DPI map
- **WHEN** a passive-netprobe DPI record classifies a flow to a device
  as `tls`
- **THEN** `device.metadata.dpi.tls.count` increments
- **AND** `device.metadata.dpi.tls.last_observed_at` is updated

### Requirement: Local Process Map on Agent-Host Devices

The `Serviceradar.Inventory.Device` Ash resource SHALL accept and
persist a `metadata.local_processes` map for devices that are also
`serviceradar-agent` hosts, populated from `ProcessSnapshot` events
emitted by `netprobe`. Each entry MUST carry the bound 5-tuple,
`pid`, `comm`, redacted `cmdline`, `uid`, and (when resolvable)
`container_id`. The map SHALL be bounded; entries MUST be evicted
under LRU to a documented maximum cardinality per device.

#### Scenario: Snapshot updates the local process map
- **WHEN** an agent host receives a `ProcessSnapshot` from its
  supervised `netprobe`
- **THEN** the agent's device record's `metadata.local_processes` is
  updated to reflect the snapshot
- **AND** entries beyond the documented cardinality limit are evicted
  under LRU

### Requirement: Passive Visibility Feeds Rule-Driven Vendor and Type Enrichment

The existing `Rule-Driven Vendor and Type Enrichment` matcher SHALL
consume `metadata.passive_fingerprint` and `metadata.dpi` payloads as
classification evidence alongside SNMP, vendor-database, and
integration-imported signals. Passive-visibility evidence MUST be
addressable in rules using stable selectors (e.g.
`metadata.passive_fingerprint.tcp.p0f_signature`,
`metadata.dpi.tls.confidence`). Precedence among signal sources MUST
remain governed by the existing rule pack and the
`Classification Provenance Visibility in Inventory` requirement.

#### Scenario: Rule promotes type_id from TCP signature
- **WHEN** an enrichment rule matches the TCP p0f signature stored on a
  device whose `type_id` is `0` (Unknown)
- **THEN** the matcher updates `type_id`, `vendor_name`, and
  `os.family` according to the rule
- **AND** `Classification Provenance` records `passive-netprobe` as the
  evidence source
