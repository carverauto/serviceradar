## ADDED Requirements

### Requirement: Dashboard WASM package class

The plugin package system SHALL support a browser-side dashboard WASM package class that is distinct from agent-executed WASM plugins.

#### Scenario: Dashboard package is discovered from a customer source
- **GIVEN** a customer-owned Git source contains a dashboard package JSON manifest
- **WHEN** the source sync reads the manifest
- **THEN** the package SHALL be classified as a dashboard package rather than an agent plugin
- **AND** it SHALL expose browser/dashboard capabilities instead of agent execution capabilities
- **AND** it SHALL NOT be assignable to agents

#### Scenario: Dashboard package declares renderer artifact
- **GIVEN** a dashboard package manifest declares a WASM renderer artifact, digest, signature metadata, and required host APIs
- **WHEN** the package is validated
- **THEN** the control plane SHALL verify artifact integrity and trust policy before enabling import
- **AND** it SHALL require an explicitly supported dashboard WASM interface version
- **AND** unsupported browser capabilities SHALL block enablement until explicitly supported by ServiceRadar

### Requirement: Dashboard WASM sandbox boundaries

Dashboard WASM renderers SHALL execute only inside the web dashboard host and SHALL receive data exclusively through approved host APIs.

#### Scenario: Renderer requests SRQL data
- **GIVEN** an enabled dashboard package declares an approved SRQL data frame
- **WHEN** the renderer requests that frame through the host API
- **THEN** web-ng SHALL authorize the current user, execute the approved SRQL server-side, and pass the resulting frame to the renderer
- **AND** the renderer SHALL NOT receive raw database credentials, service tokens, Git credentials, or agent plugin credentials

#### Scenario: Renderer uses the versioned data provider
- **GIVEN** a dashboard renderer runs under `dashboard-wasm-v1`
- **WHEN** it needs dashboard data
- **THEN** it SHALL read only the data frames exposed through the versioned host data-provider imports
- **AND** it SHALL NOT subscribe directly to internal database, MQTT, repository, or browser network sources

#### Scenario: Renderer requests an unapproved capability
- **GIVEN** a dashboard renderer requests network, repository, filesystem, secret, or unapproved ServiceRadar API access
- **WHEN** the dashboard host evaluates the request
- **THEN** the host SHALL deny the request
- **AND** the package diagnostics SHALL record the denied capability without exposing secret values

### Requirement: Customer-owned Git plugin sources

The control plane SHALL allow authorized operators to register customer-owned Git repositories as plugin catalog sources without treating those repositories as first-party ServiceRadar sources.

#### Scenario: Operator registers a private customer plugin source
- **GIVEN** an authorized operator has a customer plugin repository URL, ref, manifest path, auth method, and trust policy
- **WHEN** they create the plugin source
- **THEN** the system SHALL store the source configuration in the `platform` schema
- **AND** it SHALL store credentials only as encrypted secret references
- **AND** it SHALL record the source type as customer-owned

#### Scenario: Customer source sync discovers plugins
- **GIVEN** a registered customer plugin source has valid credentials and a reachable manifest
- **WHEN** the source sync runs manually or on schedule
- **THEN** the control plane SHALL fetch the configured manifest or index
- **AND** it SHALL list discovered plugin IDs, names, versions, package digests, declared capabilities, and source provenance
- **AND** it SHALL persist sync status, timestamp, and diagnostics for the UI

### Requirement: Customer plugin verification and staging

The control plane SHALL verify customer-owned plugin packages against the source trust policy before mirroring package content and staging the plugin for review.

#### Scenario: Verified customer plugin is staged
- **GIVEN** a customer source manifest references a plugin package with matching digest and valid signature under the configured trust policy
- **WHEN** the import workflow runs
- **THEN** the control plane SHALL fetch the package payload
- **AND** validate the bundle using the standard plugin package validation path
- **AND** mirror the package contents into ServiceRadar-managed plugin storage
- **AND** create or update a staged plugin package with source, digest, signature, and verification metadata

#### Scenario: Customer plugin verification fails closed
- **GIVEN** a customer source manifest references a package with a missing digest, mismatched checksum, invalid signature, untrusted signing key, or unsupported manifest schema
- **WHEN** the import workflow runs
- **THEN** the control plane SHALL reject the package
- **AND** no distributable plugin package SHALL be created or updated from that artifact
- **AND** the source sync diagnostics SHALL expose the failure reason

### Requirement: Customer repository isolation from agents

Agents SHALL receive only ServiceRadar-managed plugin package references and SHALL NOT receive customer repository URLs, repository credentials, or source manifests.

#### Scenario: Approved customer plugin is assigned
- **GIVEN** a verified customer plugin package has been staged, reviewed, and approved
- **WHEN** an operator assigns it to an agent
- **THEN** the next agent config SHALL include only the internal package reference, content hash, approved capabilities, and assignment configuration
- **AND** it SHALL NOT include customer repository URLs, Git credentials, or source sync tokens

#### Scenario: Unapproved customer plugin is blocked
- **GIVEN** a customer plugin package has been discovered or staged but not approved
- **WHEN** an operator or automation attempts to assign it to an agent
- **THEN** the assignment SHALL be rejected
- **AND** the package SHALL remain unavailable for execution

### Requirement: File-read host capability for seed plugins

The agent runtime SHALL provide customer seed-data plugins with no raw filesystem access unless an explicit file-read capability and approved file roots are configured.

#### Scenario: Approved seed file is readable
- **GIVEN** a plugin assignment includes a `read_file` capability and approved file roots
- **AND** the plugin requests a CSV file under an approved root
- **WHEN** the runtime handles the file-read request
- **THEN** it SHALL return the file content subject to configured size limits
- **AND** it SHALL record diagnostics suitable for plugin execution auditing

#### Scenario: Unapproved seed file is denied
- **GIVEN** a plugin requests a host file outside the approved file roots
- **WHEN** the runtime handles the file-read request
- **THEN** it SHALL deny the request
- **AND** the plugin SHALL receive a bounded error without access to file content

### Requirement: Plugins cannot mutate database schema

Customer plugin packages and plugin execution SHALL NOT create, alter, or drop database schema objects at runtime.

#### Scenario: Plugin package declares schema DDL
- **GIVEN** a customer plugin package or source manifest declares SQL DDL, migrations, or schema mutation instructions
- **WHEN** the package is validated or staged
- **THEN** the control plane SHALL reject those schema mutation instructions as executable plugin behavior
- **AND** any required ServiceRadar schema work SHALL be handled through platform-owned Elixir migrations in the `platform` schema

#### Scenario: Plugin result contains schema mutation payload
- **GIVEN** a running plugin emits a result payload that attempts to request table creation, table alteration, or arbitrary SQL execution
- **WHEN** core-elx ingests the plugin result
- **THEN** core-elx SHALL ignore or reject the schema mutation request
- **AND** no DDL SHALL be executed from the plugin payload
