## ADDED Requirements

### Requirement: Source-Authoritative Automatic Merge Fence

Every automatic device merge or authoritative identifier reassignment SHALL
preflight the complete set of affected devices and SHALL block a write that
would combine disjoint, non-empty current source-authoritative ID sets for the
same partition and source instance.

#### Scenario: Pair merge has different Armis IDs

- **GIVEN** device D1 carries current source-authoritative Armis ID A
- **AND** device D2 carries current source-authoritative Armis ID B for the same
  partition and source instance
- **AND** A and B are distinct
- **WHEN** an automatic reconciliation path proposes merging D1 and D2 because
  of MAC, IP, hostname, or other generic identity evidence
- **THEN** the merge SHALL be blocked before any device, identifier, or
  association write
- **AND** the system SHALL persist the proposed members, both source-ID sets,
  evidence, initiator, and block reason

#### Scenario: Transitive component hides a source-ID conflict

- **GIVEN** an automatic duplicate component connects D1 to D2 and D2 to D3
- **AND** D1 and D3 carry distinct non-empty source-authoritative ID sets
- **WHEN** component reconciliation begins
- **THEN** the preflight SHALL evaluate the entire component before the first
  pair is merged
- **AND** no partial merge in that component SHALL occur

#### Scenario: Source alias candidate does not bypass merge fence

- **GIVEN** distinct Armis IDs share hardware evidence or an approved source
  alias relationship
- **WHEN** an automatic canonical device merge is proposed
- **THEN** the source alias evidence SHALL NOT by itself authorize merging the
  authoritative identifiers
- **AND** any explicit bypass SHALL require a separately authorized,
  append-only audited repair contract

#### Scenario: Concurrent identifier change invalidates preflight

- **GIVEN** an automatic merge has read the affected source-ID sets
- **AND** another transaction changes authoritative identifier ownership before
  the merge writes
- **WHEN** the merge attempts to commit
- **THEN** the merge SHALL revalidate under its write lock or abort
- **AND** it SHALL NOT commit based on stale source-ID evidence

### Requirement: Armis Multi-Identifier Remediation Convergence

The system SHALL provide a bounded, dry-run-first, idempotent remediation path
for canonical devices carrying multiple Armis IDs, and SHALL classify each ID
against a complete activated source collection before proposing a mutation.

#### Scenario: One current ID and stale extras

- **GIVEN** a canonical device carries multiple historical typed Armis IDs
- **AND** exactly one of those IDs is present in the selected complete
  collection
- **WHEN** remediation dry-run evaluates the device
- **THEN** it SHALL identify the current ID and each stale extra
- **AND** it SHALL propose a mutation only when the configured absence rule and
  audit evidence prove the stale disposition is safe
- **AND** it SHALL preserve prior ownership and the decision evidence in an
  append-only manifest

#### Scenario: Multiple IDs remain current

- **GIVEN** a canonical device carries two or more Armis IDs present in the
  selected complete collection
- **WHEN** remediation dry-run evaluates the device
- **THEN** it SHALL classify the row as an unresolved source-alias or over-merge
  candidate
- **AND** it SHALL NOT delete, collapse, or fan out those IDs automatically
  without independent evidence and explicit approval

#### Scenario: Repair is verified after writers run again

- **GIVEN** an approved remediation batch changed identifier ownership or
  metadata
- **WHEN** the mutation transaction completes
- **THEN** the tool SHALL immediately re-read every changed artifact and fail
  if the intended ownership is not present
- **AND** verification SHALL remain incomplete until a fresh inbound collection
  and a later northbound run satisfy their per-source-ID reconciliation
  equations
- **AND** a successful repair job status alone SHALL NOT mark the population
  converged

#### Scenario: Remediation prevention is not deployed

- **GIVEN** an automatic writer can still recreate disjoint source-ID merges
- **WHEN** an operator requests apply-mode remediation
- **THEN** apply mode SHALL fail before changing data
- **AND** dry-run reporting MAY continue so the population can be reviewed
