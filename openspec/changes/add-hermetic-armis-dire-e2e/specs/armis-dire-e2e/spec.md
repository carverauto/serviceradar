## ADDED Requirements

### Requirement: Standalone Armis/DIRE E2E execution

The project SHALL provide a hermetic Armis/DIRE integration test command that
uses a locally started faker and an isolated test database, and SHALL NOT
require Kubernetes resources, a real Armis tenant, NATS, an agent, or a gateway.

#### Scenario: Developer runs the fast profile without Kubernetes

- **GIVEN** the developer has the repository's documented local test
  prerequisites
- **WHEN** the developer runs the Armis/DIRE E2E command with no cluster
  configuration
- **THEN** the command SHALL start faker on loopback, provision or use an
  isolated test database, run the test, and clean up child processes/resources
- **AND** the command SHALL return a non-zero exit status for any failed
  identity, availability, or northbound assertion

### Requirement: Real faker pagination and discovery cardinality

The E2E harness SHALL consume the faker's real Armis authentication and paged
search API through the production sync mapping contract, and SHALL verify that
the complete configured device population reaches core discovery without page
loss or duplicate typed identities.

#### Scenario: Population crosses multiple API pages

- **GIVEN** faker is configured with a deterministic population larger than one
  API page and a page size that does not evenly divide the population
- **WHEN** the Armis discovery fixture runs
- **THEN** every faker device ID SHALL be emitted exactly once
- **AND** every emitted update SHALL retain its typed `armis_device_id` and
  source linkage
- **AND** the core inventory SHALL contain the expected number of canonical
  devices and typed Armis identifiers

#### Scenario: Fifty-thousand-device scale profile

- **GIVEN** the scale profile is configured for 50,000 faker devices
- **WHEN** the discovery and identity pipeline completes
- **THEN** the test SHALL verify the 50,000-device cardinality and bounded
  identifier growth without requiring a Kubernetes deployment

### Requirement: DHCP churn preserves source identity

The E2E harness SHALL exercise faker IP churn and SHALL verify that active-IP
changes or collisions cannot replace a typed source-authoritative Armis identity
or attach it to an unrelated canonical device.

#### Scenario: Device IP changes between discovery and sweep

- **GIVEN** a faker device has typed Armis ID A and its IP changes during a
  churn cycle
- **WHEN** discovery and ICMP/TCP sweep results for the changed IP are ingested
- **THEN** DIRE SHALL retain one canonical device for Armis ID A
- **AND** the typed identifier SHALL not move to the prior IP owner or create a
  duplicate source device

#### Scenario: Active IP collision with distinct source identity

- **GIVEN** two source devices have distinct typed Armis IDs and a churn cycle
  makes their active IP evidence collide
- **WHEN** the update batch is reconciled
- **THEN** neither typed Armis ID SHALL be rebound to the other device
- **AND** the collision SHALL be represented by the documented conflict
  disposition rather than silently redirecting northbound state

### Requirement: Identity-conflict dispositions are explicit and bounded

The E2E harness SHALL exercise legacy and malformed identity states and SHALL
assert that only the intentionally conflicted devices are withheld from
northbound updates.

#### Scenario: Stale generic Armis bridge is present

- **GIVEN** a legacy `integration_id` row for an Armis ID points at a different
  device than the typed `armis_device_id` row
- **WHEN** the northbound candidate query runs
- **THEN** the generic row SHALL NOT become an authoritative Armis candidate
- **AND** the clean typed owner SHALL remain eligible
- **AND** the run's skipped count SHALL not be inflated by one row per stale
  identifier record

#### Scenario: Metadata disagrees with typed Armis identity

- **GIVEN** a device's metadata Armis ID differs from its source-scoped typed
  identifier
- **WHEN** the candidate query and northbound run execute
- **THEN** the device SHALL be withheld or repaired according to the documented
  conflict policy
- **AND** no update SHALL be sent for the wrong metadata ID

#### Scenario: Device has multiple typed Armis IDs

- **GIVEN** one canonical device carries multiple typed Armis IDs
- **WHEN** the northbound run executes
- **THEN** the ambiguous device SHALL be withheld with the
  `multiple_typed_ids_per_device` disposition
- **AND** all unrelated clean devices SHALL still be updated
- **AND** persisted `updated_count + skipped_count` SHALL equal the candidate
  population for that run

#### Scenario: Safe repair restores an eligible device

- **GIVEN** the identity audit identifies a safe metadata repair and a separate
  ambiguous multi-ID device
- **WHEN** the safe repair is applied and northbound is run again
- **THEN** the repaired device SHALL receive its one expected Armis update
- **AND** the ambiguous device SHALL remain withheld and visible for review

### Requirement: Source-scoped identity isolation

The E2E harness SHALL prove that an identical numeric source identifier in two
integration sources does not merge their canonical devices or leak one source's
availability into the other source's northbound updates.

#### Scenario: Same numeric ID belongs to two sources

- **GIVEN** source A and source B each contain an Armis device with the same
  numeric identifier but distinct source linkage
- **WHEN** both sources are ingested and each northbound run executes
- **THEN** each source SHALL retain its own canonical identity and availability
- **AND** each faker endpoint/capture SHALL receive only its source's update

### Requirement: Sweep availability reaches northbound Armis exactly once

The E2E harness SHALL route representative ICMP and TCP sweep outcomes through
the core availability ingestion path and SHALL assert one bulk custom-property
operation per eligible Armis device per run.

#### Scenario: Mixed ICMP/TCP availability population

- **GIVEN** discovery has produced N clean typed Armis devices and sweep
  fixtures contain available, unavailable, and mixed ICMP/TCP outcomes
- **WHEN** the northbound run executes against faker
- **THEN** faker SHALL capture exactly N successful device operations
- **AND** every operation SHALL target a known typed Armis ID
- **AND** the submitted property values SHALL match the persisted consolidated
  availability for each device
- **AND** there SHALL be zero missing-device operations and zero execution
  errors

#### Scenario: Repeated run is idempotent

- **GIVEN** the same clean discovery and sweep state is run through northbound
  twice
- **WHEN** the second run completes
- **THEN** it SHALL produce one operation per eligible Armis ID for that run
- **AND** it SHALL not create duplicate canonical devices or new identifier
  rows solely because the run was repeated

### Requirement: Manual Oban execution is covered

The E2E suite SHALL cover the persisted Oban worker path used by the manual
“run northbound now” action, in addition to direct runner assertions.

#### Scenario: Manual run worker completes successfully

- **GIVEN** an enabled Armis source has completed discovery and sweep ingestion
- **WHEN** the test enqueues and performs the northbound worker
- **THEN** the worker SHALL complete successfully
- **AND** the persisted integration update run SHALL record the same device,
  updated, skipped, and error counts observed by the test
- **AND** the faker capture SHALL agree with the persisted successful updates

### Requirement: Failure diagnostics are preserved

The E2E command SHALL preserve enough local artifacts to identify page loss,
identity drift, availability mismatch, and northbound write-count mismatch
without access to a cluster.

#### Scenario: E2E assertion fails

- **WHEN** any E2E assertion fails
- **THEN** the command SHALL preserve faker logs, the emitted fixture/chunk
  artifact, captured northbound operations, identity conflict summaries, and
  persisted run metadata
- **AND** the command SHALL print the artifact directory and exit non-zero
