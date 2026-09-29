## ADDED Requirements

### Requirement: Sandboxed external inventory plugin
The system SHALL support signed external Go/TinyGo Wasm packages that acquire provider inventory through approved host capabilities and emit assignment-approved binary inventory pages and terminal manifests through the agent-owned durable producer sink. `serviceradar.plugin_result.v1` SHALL remain limited to bounded action/check status and MUST NOT carry persistent inventory pages. A plugin MUST NOT access ServiceRadar databases, NATS, transport frames, broker subjects, the host filesystem, raw sockets, or arbitrary internal APIs unless a separately approved capability explicitly provides that access.

#### Scenario: Inventory collection runs at the assigned edge
- **GIVEN** an approved inventory package is assigned to an agent that can reach its provider
- **WHEN** the agent executes the package action
- **THEN** the plugin SHALL use only approved configuration and host capabilities
- **AND** its inventory SHALL enter ServiceRadar as bounded typed records through the common durable producer sink
- **AND** any source credential or derived access token SHALL remain inside trusted host adapters
- **AND** the command result SHALL contain only bounded status, counts, identifiers, and hashes

#### Scenario: Unapproved capability is requested
- **GIVEN** the package was not approved for a requested host capability or endpoint
- **WHEN** the plugin attempts to use it
- **THEN** the agent SHALL deny the operation
- **AND** no inventory snapshot SHALL be activated

### Requirement: Package-owned integration declaration
An external inventory package SHALL own its provider identity, config JSON Schema, operator documentation, credential profile and field schema, producer-schedule binding, inventory source label, source metadata display fields, and provider tests. Core SHALL consume only a bounded validated declarative descriptor and SHALL NOT require provider-specific modules, provider allowlists, forms, or static catalog entries.

#### Scenario: New provider package is approved
- **GIVEN** a signed package declares a valid unique provider, schedule binding, inventory source, config schema, and bundled documentation
- **WHEN** an operator approves the package
- **THEN** ServiceRadar SHALL expose its provider and source through generic runtime catalogs
- **AND** no core source change SHALL be required

#### Scenario: Package claims an existing provider
- **GIVEN** two approved package versions from different plugins claim the same provider or source
- **WHEN** the runtime catalog is built
- **THEN** ServiceRadar SHALL reject the ambiguous claim
- **AND** it SHALL NOT choose a provider by load order

#### Scenario: Package references missing documentation
- **GIVEN** a package descriptor names a documentation path not present in its bundle
- **WHEN** import validation runs
- **THEN** import SHALL fail safely
- **AND** core SHALL NOT substitute provider-specific documentation

### Requirement: Platform-owned recurring and on-demand execution
An inventory package MAY declare an assignment-scoped producer schedule using `plugin.run_action`. ServiceRadar workers and the agent command bus SHALL own recurring and Run Now dispatch; the plugin SHALL NOT implement an internal timer.

#### Scenario: Recurring collection becomes due
- **GIVEN** an enabled package-declared producer schedule is due
- **WHEN** the schedule worker runs
- **THEN** it SHALL dispatch the declared action to the selected agent through the command bus
- **AND** it SHALL record run state and next due time

#### Scenario: Operator runs collection now
- **GIVEN** an authorized operator opens a package integration rule
- **WHEN** the operator selects Run Now
- **THEN** ServiceRadar SHALL dispatch the same package action through the same command path
- **AND** RBAC, audit, timeout, credential, and result policies SHALL remain identical

### Requirement: Complete bounded inventory snapshots
An inventory plugin SHALL stream independently bounded source-snapshot pages while collection is in progress and SHALL emit a bounded terminal manifest only after provider collection completes within package and platform page, row, metadata, byte, duration, and outstanding-record limits. Every page SHALL have a stable idempotency key and content digest. A complete terminal SHALL bind the exact source instance, coverage scope, page/object counts, bounded Merkle or checkpoint root, and a provider snapshot token/revision or contract-specific consistency proof. A partial, malformed, duplicate-conflicting, non-advancing, stale, missing-page, or oversized run MUST NOT replace current source inventory.

#### Scenario: Complete collection succeeds
- **GIVEN** all provider pages complete and every source object is valid and unique
- **WHEN** the plugin emits a complete terminal manifest
- **THEN** the staged run SHALL identify the source, source instance, coverage scope, collection, observed time, page/object counts, content root, provider consistency proof, and completion state
- **AND** ServiceRadar SHALL activate the source observations with one atomic current-version pointer swap only after every declared page and canonical reconciliation validates

#### Scenario: Collection exceeds bounds
- **GIVEN** provider results exceed an approved row, metadata, or serialized-byte limit
- **WHEN** the bound is reached
- **THEN** the run SHALL fail with a stable bounded error
- **AND** the previous complete source snapshot SHALL remain current

#### Scenario: A terminal arrives with a missing or conflicting page
- **GIVEN** inventory pages have been staged for a run
- **WHEN** its complete terminal references a missing page, conflicting content digest, duplicate source object, or inconsistent provider revision
- **THEN** activation SHALL fail deterministically
- **AND** the previous current snapshot SHALL remain unchanged

#### Scenario: Provider cannot prove a consistent complete view
- **GIVEN** a provider exposes pagination without a snapshot token, revision, or contract-approved consistency proof
- **WHEN** an inventory run completes
- **THEN** ServiceRadar MAY apply validated observations as upserts
- **AND** it SHALL NOT infer absence or deletion for objects omitted from that run

### Requirement: Generic source normalization
Each valid inventory row SHALL carry a bounded source object ID, a stable source-prefixed integration ID, standard canonical device fields, and optional provider values only under `source_metadata`. Raw provider rows and unapproved secret or protocol fields SHALL NOT be forwarded.

#### Scenario: Provider row is normalized
- **GIVEN** a provider row has stable source identity and standard hostname, address, hardware, vendor, model, type, location, or state fields
- **WHEN** the plugin normalizes it
- **THEN** standard fields SHALL use the generic device discovery contract
- **AND** declared provider display values SHALL be placed under `source_metadata`

#### Scenario: Raw provider data contains extra fields
- **WHEN** a provider response includes values outside the approved mapping
- **THEN** the plugin SHALL omit the raw row and unapproved values
- **AND** credentials, tokens, contacts, and request internals SHALL not enter inventory metadata
