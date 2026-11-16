# Spec Deltas: set-based-sweep-lease-issuance - sweep-jobs

## ADDED Requirements

### Requirement: Lease issuance and slot minting transactions are statement-bounded
Lease delivery and lease planning SHALL size their transactions by rows, and
no transaction on either path SHALL issue a number of SQL statements that grows
with the rows it writes beyond one bulk statement per fixed-size row batch.

Lease delivery SHALL commit a window's issuance evidence in chunks of at most
512 entries, each through the set-based issuance commit, and SHALL still
commit all of it before recording the push and sending it; a conflicting entry
SHALL still halt the push before anything is sent. Lease planning SHALL mint an
assignment's new slots with bulk inserts of at most 250 rows each, inside the
transaction that holds the sweep group row; a slot whose plan cannot be built
SHALL be counted as an error and skipped while the rest are minted, and a
database error on an insert SHALL roll back that planning transaction.

#### Scenario: A full-window re-push commits in a handful of short transactions
- **GIVEN** an agent holding about 2,016 unrun slots (4,032 evidence entries)
- **WHEN** a session refresh re-pushes the whole window
- **THEN** the issuance evidence SHALL commit in at most eight transactions
- **AND** each transaction SHALL issue at most ten SQL statements
- **AND** each SHALL complete well inside the 15 s checkout timeout.

#### Scenario: Minting a thousand slots takes a few inserts
- **GIVEN** an assignment whose horizon needs 1,000 new slots
- **WHEN** the lease pass plans it
- **THEN** the slots SHALL be inserted with at most four insert statements.
