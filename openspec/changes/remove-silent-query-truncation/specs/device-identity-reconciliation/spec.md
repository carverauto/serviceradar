## ADDED Requirements

### Requirement: Batch identity preloads are complete
The batch resolver MUST load every candidate device id when it preloads tombstones, agent trust, or canonical MAC state. A candidate missing from a truncated page MUST NOT be treated as live, untrusted, or without a MAC.

#### Scenario: Tombstone check covers the whole batch
- **WHEN** a batch contains more candidate device ids than one default page of `Device.read`
- **THEN** every tombstoned id in that batch SHALL be reported as tombstoned

#### Scenario: Agent trust preload covers the whole batch
- **WHEN** agent-id matches in one batch point at more devices than one default page
- **THEN** the trust decision for each of those devices SHALL use that device's own row
