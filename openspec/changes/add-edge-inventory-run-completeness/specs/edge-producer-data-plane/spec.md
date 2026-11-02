# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Run and snapshot lifecycles are bounded and explicit
A finite producer run SHALL use host-issued start, independently useful data,
bounded checkpoint, and complete/partial/aborted terminal identities. A
perpetual producer SHALL rotate bounded epochs. RPC close, producer exit, or the
last received page SHALL NOT imply completion.

Atomic snapshot pages SHALL be staged immutably by assignment-authorized source
instance and scheduler-owned generation without current-state or absence side
effects. A terminal MAY wait pending until every declared page ordinal/hash and
object-key uniqueness check succeeds and its bounded ordered Merkle/checkpoint
root validates. Activation SHALL atomically fence older generations and swap the
source's current snapshot pointer. Conflicting pages/terminals, abort-after-
complete, and late older terminals SHALL NOT replace current state; abandoned
staging SHALL have bounded repair retention and garbage collection.

Absence/deletion SHALL require a complete terminal with an assignment-scoped
provider snapshot token/revision or contract-specific consistency proof and
exact coverage scope. Without that proof, the run SHALL be upsert-only.

#### Scenario: Terminal arrives before one page
- **WHEN** a snapshot terminal arrives before all pages named by its root
- **THEN** the terminal SHALL remain pending and current inventory SHALL remain
  unchanged
- **AND** activation MAY occur only after the missing page commits and the full
  root validates

#### Scenario: Provider changes during pagination
- **GIVEN** received pages are individually valid but no consistent provider
  snapshot token/revision or equivalent proof exists
- **WHEN** the run terminates successfully
- **THEN** its records MAY upsert observed objects
- **AND** it SHALL NOT infer absence or delete previously current objects

#### Scenario: A stale complete terminal arrives late
- **WHEN** an older generation completes after a newer generation became current
- **THEN** the older terminal SHALL NOT move the current pointer backward
- **AND** conflicting same-generation evidence SHALL be quarantined as an
  integrity failure

#### Scenario: Armis discovery emits provider pages
- **WHEN** the inbound Armis integration receives a bounded provider page
- **THEN** it SHALL emit a typed inventory page through the shared producer sink
  without whole-run JSON materialization or Core coalescing
- **AND** current inventory absence SHALL remain unchanged until a valid
  consistency-proven complete terminal activates the snapshot

#### Scenario: Armis northbound update is requested
- **WHEN** ServiceRadar must POST desired state to Armis
- **THEN** the HTTP side effect SHALL remain an idempotent command/job-plane
  action and SHALL NOT execute from EventWriter replay
- **AND** only bounded receipts, audit, progress, and telemetry MAY return
  through the durable record plane

