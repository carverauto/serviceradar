## ADDED Requirements

### Requirement: Passive Fingerprint Is a Weak Identity Signal

`device-identity-reconciliation` SHALL treat passive fingerprint
evidence (TCP p0f, TLS JA4/JA4S, HTTP signatures) and DPI protocol
classification as *weak* identifier signals in
`Multi-Identifier Convergence`. Passive evidence MUST NOT be sufficient
on its own to merge two device records that share no strong or medium
identifier. It MAY raise confidence in a merge already supported by
stronger identifiers.

#### Scenario: Matching p0f without shared MAC does not merge
- **WHEN** two distinct devices each have the same TCP p0f signature
- **AND** they share no MAC, no canonical IP, and no
  integration-provided unique identifier
- **THEN** the reconciliation pipeline does not merge them

#### Scenario: Passive fingerprint corroborates an MAC-based merge
- **WHEN** two records share an interface MAC and are scheduled for
  merge under existing rules
- **AND** the same TCP p0f signature is observed on both records
- **THEN** the merge proceeds
- **AND** the reconciliation provenance records `passive-netprobe` as
  corroborating evidence

### Requirement: Local-Process Identity for Agent-Host Devices

The reconciliation pipeline SHALL treat the local-process map sourced
from `netprobe`'s `ProcessSnapshot` events as authoritative for an
agent-host device's process inventory, scoped via the existing agent
→ device association rather than identifier merging.

#### Scenario: Process snapshot does not synthesize new device records
- **WHEN** a `ProcessSnapshot` from an agent host arrives at the
  reconciliation pipeline
- **THEN** the pipeline updates the agent host's existing device
  record's process map
- **AND** does not create new device records for the listed processes
