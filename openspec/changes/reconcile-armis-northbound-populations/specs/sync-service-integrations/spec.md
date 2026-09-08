## ADDED Requirements

### Requirement: Armis Collection Population Accounting

The system SHALL bind Armis inbound population counts to a successfully
activated complete source collection and SHALL account separately for raw rows,
policy-excluded rows, invalid rows, valid source-ID occurrences, distinct
normalized Armis IDs, and duplicate occurrences.

For an accounted collection, `raw_rows` SHALL equal `excluded_rows +
invalid_rows + valid_occurrences`, and `valid_occurrences` SHALL equal
`distinct_source_ids + duplicate_occurrences`.

#### Scenario: Complete collection contains compatible repeated rows

- **GIVEN** configured Armis queries or pages return N raw rows
- **AND** two or more rows carry the same normalized Armis ID with compatible
  identity-critical fields
- **WHEN** the complete collection is activated
- **THEN** the collection SHALL retain one source observation for that distinct
  Armis ID
- **AND** every additional occurrence SHALL increment `duplicate_occurrences`
- **AND** the raw-row and valid-occurrence equations SHALL hold
- **AND** compatible repeated rows SHALL NOT be counted as northbound skips

#### Scenario: Repeated Armis ID has conflicting payloads

- **GIVEN** two rows in one collection carry the same normalized Armis ID
- **AND** their identity-critical fields conflict under the configured policy
- **WHEN** the collection is normalized
- **THEN** the collection SHALL record that ID as a conflicting duplicate
- **AND** it SHALL retain enough bounded evidence to diagnose the disagreement
- **AND** it SHALL NOT silently choose a payload by page or query order

#### Scenario: Incomplete collection cannot become the accounting basis

- **GIVEN** an Armis run is missing a page, fails validation, or is not marked
  complete
- **WHEN** source collection activation is evaluated
- **THEN** that collection SHALL NOT replace the last successfully activated
  collection
- **AND** a northbound run SHALL NOT use its partial counts or membership

#### Scenario: Legacy collection lacks exact accounting

- **GIVEN** an activated collection predates the exact population fields
- **WHEN** the operator views its inbound population
- **THEN** the system SHALL label population accounting unavailable
- **AND** it SHALL NOT present an inferred active-canonical count as an exact
  Armis import count

### Requirement: Collection-Bound Armis Northbound Reconciliation

Each Armis northbound run SHALL bind to one complete activated source collection
for the configured partition and source instance and SHALL persist one immutable
disposition for every distinct source ID in that collection.

The run SHALL satisfy `distinct_source_ids = eligible_ids + withheld_ids` and
`eligible_ids = accepted_ids + failed_ids + unattempted_ids` before it can be
reported as population-reconciled.

#### Scenario: Clean collection is fully accepted

- **GIVEN** a complete activated collection contains N distinct valid Armis IDs
- **AND** every ID resolves safely to current canonical availability
- **WHEN** Armis accepts every northbound batch
- **THEN** the run SHALL persist N eligible and N accepted source-ID
  dispositions
- **AND** withheld, failed, and unattempted counts SHALL be zero
- **AND** both reconciliation equations SHALL hold

#### Scenario: Source ID is unsafe for outbound use

- **GIVEN** a source ID belongs to the bound collection
- **AND** its canonical resolution has ambiguous identity, invalid source
  linkage, missing required availability, or another safety conflict
- **WHEN** the northbound population is materialized
- **THEN** that source ID SHALL receive exactly one withheld disposition and
  reason
- **AND** it SHALL NOT appear in an outbound payload
- **AND** diagnostics that do not withhold a source ID SHALL not inflate the
  withheld count

#### Scenario: Batch failure leaves later IDs unattempted

- **GIVEN** a collection-bound run has multiple eligible outbound batches
- **AND** one batch fails and execution stops
- **WHEN** the run is finalized
- **THEN** IDs in the failed batch SHALL be recorded as failed
- **AND** eligible IDs in later batches SHALL be recorded as unattempted
- **AND** IDs in earlier accepted batches SHALL remain accepted
- **AND** the eligible-ID equation SHALL hold

#### Scenario: Activated collection changes after run start

- **GIVEN** a northbound run has bound and materialized collection C1
- **AND** a newer collection C2 becomes active while the run is executing
- **WHEN** the run completes or is inspected later
- **THEN** all dispositions and totals SHALL continue to describe C1
- **AND** C2 SHALL be eligible only as the basis of a later run

### Requirement: Armis Source Duplicate and Alias Classification

The system SHALL distinguish repeated rows for the same normalized Armis ID
from distinct Armis IDs that may represent one physical asset. Distinct source
IDs SHALL NOT be treated as proven duplicates based only on shared canonical
UID, IP, MAC, serial number, hostname, or prior ServiceRadar merge state.

#### Scenario: Distinct Armis IDs share a canonical device

- **GIVEN** distinct current Armis IDs A and B resolve to one canonical device
- **AND** there is no independently verified source alias relationship
- **WHEN** the northbound reconciliation run evaluates A and B
- **THEN** the system SHALL report them as source-alias or over-merge candidates
- **AND** it SHALL NOT infer that one ID is a duplicate occurrence of the other
- **AND** it SHALL NOT fan out an outbound value solely because they share the
  canonical device

#### Scenario: Approved alias relationship permits explicit fan-out

- **GIVEN** distinct Armis IDs A and B have independent source-side evidence or
  an operator-approved, audited alias relationship
- **WHEN** northbound policy explicitly permits alias fan-out
- **THEN** A and B MAY each receive one source-ID disposition and outbound
  update
- **AND** their separate operations SHALL remain visible in the accepted count
- **AND** the alias relationship SHALL NOT by itself merge their authoritative
  source identifiers

### Requirement: Armis Population Reconciliation Visibility

The Integration Sources UI and northbound events SHALL expose collection-bound
population accounting and SHALL keep transport execution status separate from
population reconciliation status.

#### Scenario: Transport succeeds with withheld source IDs

- **GIVEN** all submitted Armis batches receive successful HTTP responses
- **AND** one or more source IDs were withheld before submission
- **WHEN** the run is displayed
- **THEN** northbound transport MAY be shown as successful
- **AND** population reconciliation SHALL be shown as degraded or withheld
- **AND** the UI SHALL display the selected collection, all reconciliation
  totals, reason groups, and both equations

#### Scenario: Operator investigates a count gap

- **WHEN** any duplicate, invalid, withheld, failed, or unattempted count is
  nonzero
- **THEN** the operator SHALL be able to view bounded examples grouped by
  mutually exclusive reason
- **AND** an authorized operator SHALL be able to retrieve the complete
  per-source-ID disposition for the run
- **AND** the UI SHALL label accepted operations as accepted by Armis rather
  than verified downstream writes
