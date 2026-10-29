## ADDED Requirements

### Requirement: Content-bound retained publication validation receipts

The disabled exposure audit prototype SHALL reuse retained-publication
validation only when the receipt matches a database-maintained fingerprint of
the complete retained payload and the active validator revision. It SHALL
retain only a validation verdict, replay digest, state and reference identities;
it SHALL NOT cache current fact results, warehouse matches or readiness.

#### Scenario: Retained content changes without a new sequence

- **WHEN** the stored retained payload changes at an equal transition sequence
- **THEN** its generated fingerprint changes and the previous receipt cannot qualify
- **AND** the affected comparison remains deferred or failed until valid evidence exists in a fresh source view

#### Scenario: Decoder or fingerprint semantics change

- **WHEN** the active validator revision differs from the receipt revision
- **THEN** the receipt cannot qualify even when the transition sequence is unchanged
- **AND** the new revision requires bounded preparation

### Requirement: Receipt reuse preserves independent exposure comparison

The prototype SHALL validate complete retained after-images through the existing
decoder before recording valid receipts, independently hash current assessment
values on every audit, and compare actual warehouse columns using the unchanged
v1 digest. Duplicate multiplicity, inactive semantics, reference coverage,
generation floors, evidence age and repair ownership SHALL remain intact.

#### Scenario: Current state drifts while replay and warehouse agree

- **WHEN** current assessment attributes differ from the fingerprint-bound retained publication
- **THEN** independent current hashing detects the disagreement
- **AND** a valid replay receipt cannot turn the scope into a successful match

#### Scenario: Terminal references remain necessary

- **WHEN** a required package version appears only in a tombstoned assessment or terminal watermark
- **THEN** its existing reference coverage remains required
- **AND** absent or malformed reference material does not vanish from coverage

#### Scenario: Warehouse recovery starts after a receipt was prepared

- **WHEN** the warehouse recovery fence advances
- **THEN** prior audit results and warehouse proofs cannot qualify
- **AND** a source receipt never substitutes for fresh warehouse evidence

### Requirement: Receipt preparation is bounded and has no publication side effects

The prototype SHALL condition receipt persistence on unchanged source content,
limit preparation pages to 500 rows under the existing two-worker budget, and
preserve progress across interruption. Receipt writes SHALL NOT allocate
transition sequences, enqueue publications, or clear repair obligations.

#### Scenario: Source changes while preparation runs

- **WHEN** a preparer attempts to store a receipt for an older fingerprint
- **THEN** its conditional write is rejected or deferred
- **AND** it cannot overwrite a receipt for the newer payload

#### Scenario: A malformed publication occupies a preparation page

- **WHEN** full validation rejects a retained publication
- **THEN** preparation records a bounded content-bound invalid verdict and advances
- **AND** the affected fact scope cannot pass by omitting that row

### Requirement: Receipt cost remains inside explicit acceptance gates

The prototype SHALL report cold preparation, source-write cost, storage,
steady-state audit and recovery cost separately and together where incurred.
It SHALL preserve the existing component and fleet gates. Prototype approval
SHALL NOT authorize a hosted allocation, fleet execution or runtime adoption.

#### Scenario: Prepared audit passes but recovery fails

- **WHEN** reuse meets a component screen but required cold preparation or recovery misses its gate
- **THEN** the result remains a failed acceptance case
- **AND** the experiment stops without a fleet attempt or runtime enablement

#### Scenario: No measurement allocation exists

- **WHEN** a disabled prototype has been approved and ordinary remote validation passes
- **THEN** a separately approved exact-commit allocation is still required before manual execution
