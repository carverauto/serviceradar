# Spec Deltas: set-based-sweep-lease-issuance - edge-producer-data-plane

## ADDED Requirements

### Requirement: Issuance evidence commits are set-based
The issuer commit boundary for assignment mappings SHALL commit a batch of
issuance entries with a fixed number of SQL statements that does not depend on
the number of entries in the batch, and SHALL decide every entry exactly as
committing the same entries one at a time, in order, within one transaction
would.

Each batch is one transaction. Every distinct mapping key in it is ensured and
locked for the rest of the transaction before any decision is made; the
per-entry decision (same-value replay, first candidate, conflicting candidate,
missing membership, corrupt evidence) is computed over the state read under
those locks plus the earlier entries of the same batch. The batch answers the
first error in entry order and rolls back, otherwise conflicting when any entry
conflicted, otherwise committed. Same-value replay keeps the first issuance
evidence and adds no rows. A commit never changes a resolver epoch, and it
fences a captured candidate generation exactly as appending the same
candidates one at a time does.

#### Scenario: Statement count is independent of batch size
- **GIVEN** two batches of new entries, one of 1 entry and one of 256
- **WHEN** each is committed
- **THEN** both SHALL issue the same number of SQL statements
- **AND** that number SHALL be at most eight plus the transaction boundaries.

#### Scenario: A mixed batch decides like one-at-a-time commits
- **GIVEN** one batch holding a new entry, a duplicate of it, a same-value
  replay of a committed entry, a differing value for a committed key, two
  differing values for a new key, a replay of a value a resolver did not
  select, and a new value for a key whose selection a resolver captured
- **WHEN** the batch is committed
- **THEN** the batch SHALL answer conflicting
- **AND** every key SHALL hold the same issuances, candidates, generation and
  selection as committing those entries one at a time in order
- **AND** a resolve with the captured token SHALL answer changed candidates.

#### Scenario: An integrity failure rolls back the whole batch
- **GIVEN** a batch whose later entry names a key that lost its candidate
  membership, or whose stored evidence no longer verifies
- **WHEN** the batch is committed
- **THEN** it SHALL answer missing, or corrupt, for the first such entry
- **AND** no entry of the batch SHALL be committed.

#### Scenario: Replaying a committed batch writes nothing new
- **GIVEN** a batch that was committed
- **WHEN** the same batch is committed again
- **THEN** it SHALL answer the same outcome
- **AND** no issuance, candidate or resolution row SHALL be added.
