## ADDED Requirements

### Requirement: Persisted Identity Decision Log
The system SHALL persist every identity decision that blocks, declines or overrides a merge
as an identity decision record naming the decision kind, the reason, every device the
decision is about, the address it concerns (if any) and the evidence, in addition to any
telemetry. Decision kinds SHALL cover merge-policy refusals, merge-guard refusals,
source-authority conflicts, IP alias invalidations, active-IP conflicts and
source-authoritative overrides. A repeat of the same decision (same kind, reason, address and
device set) SHALL update its existing record's occurrence count, last decision time and
evidence instead of adding a record. Identity decision records SHALL be readable by any
viewer and writable only by the system.

#### Scenario: A refused merge is recorded
- **GIVEN** an update whose identifiers match two devices only through randomized MACs
- **WHEN** the merge policy refuses to merge them
- **THEN** an identity decision record of kind `policy_block` SHALL name both devices
- **AND** it SHALL carry the matched identifiers as evidence

#### Scenario: A merge guard refusal is recorded
- **GIVEN** two devices bound to different agents
- **WHEN** an automatic merge of the two is refused by the distinct-agent guard
- **THEN** an identity decision record of kind `guard_block` SHALL name both devices and the
  guard

#### Scenario: An alias invalidation is recorded
- **GIVEN** a confirmed IP alias held by a device whose identity conflicts with the device now
  seen at that address
- **WHEN** the alias is marked stale instead of merging the devices
- **THEN** an identity decision record of kind `alias_invalidated` SHALL name both devices and
  the address

#### Scenario: A repeated decision does not add records
- **GIVEN** an identity decision record for a refused merge
- **WHEN** the same merge is refused again
- **THEN** the existing record's occurrence count SHALL increase by one
- **AND** no second record SHALL be written

#### Scenario: Administrative merges are not decisions
- **WHEN** an administrator merges two devices
- **THEN** no identity decision record SHALL be written for that merge
