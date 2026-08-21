## ADDED Requirements

### Requirement: Episodes survive a device identity transition
The pipeline SHALL keep one logical anomaly represented as one episode across a device
identity transition, and SHALL NOT report a condition as resolved merely because the device
it was observed on was merged away. Episode identity is content-addressed on the device id
(`episode_uid` derives from `finding_uid`, which embeds the device uid), so a merge cannot
rewrite it in place; this requirement is met by repointing and lineage rather than by
reassignment.

On a transition, open episodes on the merged-away device SHALL be repointed to the canonical
device for device-scoped reads, and lineage SHALL be recorded linking the previous finding
identity to its successor. When a report arrives under the successor identity while lineage
for an open episode exists, ingest SHALL continue that episode rather than opening a new one
with a fresh baseline.

An episode that is closed because its device was merged away, rather than because the
condition ended, SHALL be distinguishable from a stale close.

#### Scenario: An open episode is not orphaned by a merge
- **GIVEN** an open anomaly episode on device A
- **WHEN** A is merged into device B
- **THEN** the episode is visible on B
- **AND** the episode remains open

#### Scenario: Reporting under the successor identity continues the episode
- **GIVEN** an open episode on device A with recorded lineage to its successor identity on B
- **WHEN** a report arrives for the same series under B
- **THEN** the existing episode is continued
- **AND** no second episode is opened for the same logical anomaly
- **AND** the episode's baseline is not reset

#### Scenario: A merge-closed episode is not reported as stale-resolved
- **GIVEN** an open episode on device A whose successor never reports
- **WHEN** the staleness window elapses
- **THEN** the episode is closed with a clear reason identifying an identity merge
- **AND** it is not closed with the reason used for a producer that simply stopped reporting

#### Scenario: Duplicate episodes are not created for one condition across a merge
- **GIVEN** a condition that persists across a merge of device A into device B
- **WHEN** an operator views anomalies for B
- **THEN** one episode represents the condition
