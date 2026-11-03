# agent-connectivity Delta

## ADDED Requirements

### Requirement: Agent durable record storage has one hard filesystem budget
The agent SHALL use one crash-safe atomic byte allocator for all durable-record
lanes, every producer-assignment quota, raw quarantine, both recovery-journal
copies, segment and directory metadata, rollover copy amplification, and scratch
space. Per-lane and per-producer quotas SHALL be subordinate to that global
limit. A hard minimum-free-space floor SHALL be unborrowable by ordinary record
data and reserved for recovery/control and terminal evidence.

#### Scenario: Nominal lane quotas exceed available disk
- **GIVEN** every individual lane remains below its configured quota
- **WHEN** their combined reservations plus quarantine, journals, and recovery
  scratch would cross the filesystem limit or minimum-free-space floor
- **THEN** the allocator SHALL refuse new ordinary producer reservations
- **AND** SHALL preserve enough space to durably abort/terminalize work and report
  or recover already-committed spool state
