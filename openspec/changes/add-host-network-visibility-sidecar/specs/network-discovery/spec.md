## ADDED Requirements

### Requirement: Passive netprobe discovery source

Discovery ingestion SHALL accept records whose `discovery_sources`
list includes `passive-netprobe`. Such records originate from the
`netprobe` sidecar on a `serviceradar-agent` and represent passive
on-wire observations (fingerprint or DPI evidence) rather than active
probes. The ingestion writer MUST NOT trigger any active probe in
response to a passive-netprobe record.

#### Scenario: Passive record is persisted without active follow-up
- **WHEN** the agent ingests a discovery record with
  `discovery_sources: ["passive-netprobe"]` for an existing device
- **THEN** the device's `discovery_sources` is updated to include
  `passive-netprobe`
- **AND** no SNMP, ICMP, TCP-probe, or other active mapper job is
  scheduled as a side effect

### Requirement: Discovery ingestion stores passive fingerprint and DPI metadata

The discovery ingestion writer SHALL persist passive-netprobe payloads
(TCP p0f, TLS JA4/JA4S, HTTP header signature, and per-protocol DPI
counters) onto the canonical `Device` resolved via
`device-identity-reconciliation`'s `IP Alias Resolution`. Storage MUST
use the `os.passive_fingerprint`, `metadata.passive_fingerprint`, and
`metadata.dpi` map keys defined in `device-inventory`, preserving the
most-recent observation per (device, protocol) without introducing new
database tables.

#### Scenario: Passive observation enriches an Armis-imported device
- **WHEN** the agent ingests a passive-netprobe record for an IP that
  belongs to a device created from an Armis sync
- **THEN** the device's `os.passive_fingerprint` is updated with the
  observed signature payload
- **AND** the device's `discovery_sources` is extended to include
  `passive-netprobe` while retaining `armis`

#### Scenario: DPI classification updates protocol mix on existing device
- **WHEN** the agent ingests a passive-netprobe record carrying a DPI
  classification (e.g. `tls`) for a device
- **THEN** the device's `metadata.dpi.tls` counter and last-observation
  timestamp are updated
- **AND** no payload-bearing fields (URIs, query names, bodies) are
  persisted on the device record
