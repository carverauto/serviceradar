## ADDED Requirements

### Requirement: Wasm check capability descriptors
Approved Wasm plugin packages SHALL be able to declare versioned check capability descriptors that describe reusable checks independently from a static plugin assignment.

#### Scenario: Plugin declares HTTP URL check
- **GIVEN** a plugin manifest includes a valid `check_descriptors` entry for `http.url.availability`
- **WHEN** the package is imported and approved
- **THEN** the descriptor SHALL be stored with the package version
- **AND** operators SHALL be able to select that descriptor when creating monitoring bindings

#### Scenario: Descriptor requests unapproved capability
- **GIVEN** a descriptor requires `http_request`
- **WHEN** an admin approves the plugin package without `http_request`
- **THEN** the descriptor SHALL NOT be assignable
- **AND** the UI SHALL explain which capability blocks the descriptor

### Requirement: Descriptor-aware assignment materialization
The control plane SHALL compile monitoring bindings into plugin assignments containing concrete target batches, stable check instance IDs, broker grant references, and descriptor metadata.

#### Scenario: Binding compiles into target batch
- **GIVEN** a binding selects 200 HTTP services
- **WHEN** the assignment compiler runs for an eligible agent
- **THEN** the generated plugin assignment SHALL include concrete target items with service IDs and check instance IDs
- **AND** it SHALL NOT include raw SRQL queries as runtime authority

#### Scenario: Credential grant is target-bound
- **GIVEN** a descriptor needs database credentials
- **WHEN** an assignment is generated for a database target
- **THEN** the assignment SHALL contain a credential broker grant reference scoped to that target, descriptor, agent, and TTL
- **AND** it SHALL NOT contain plaintext username/password, token, private key, cookie, or client key material

### Requirement: Target-scoped plugin results
Plugin result ingestion SHALL accept target-scoped results that identify the monitored service, optional device, check instance, descriptor, and binding that produced the result.

#### Scenario: Plugin reports per-target result
- **GIVEN** a plugin executes a batch containing multiple URL services
- **WHEN** it reports one result per target
- **THEN** ingestion SHALL update each corresponding check instance independently
- **AND** one failed target SHALL NOT make unrelated targets appear failed

#### Scenario: Missing target identity is rejected for descriptor binding
- **GIVEN** a plugin assignment was generated from a monitoring binding
- **WHEN** a plugin result omits the required check instance or target identity
- **THEN** ingestion SHALL reject that target result as invalid
- **AND** the assignment health SHALL report a malformed result without updating unrelated service state

### Requirement: Built-in checks use the same service monitoring model
Built-in checks such as ICMP, TCP connect, and TLS certificate expiry SHALL expose descriptor-like capabilities so operators use the same binding workflow for built-in and Wasm-backed checks.

#### Scenario: TCP connect appears beside plugin checks
- **GIVEN** an operator creates monitoring for a service target
- **WHEN** built-in TCP connect is available for that target kind
- **THEN** the UI SHALL present it in the same eligible capability list as plugin checks
- **AND** its results SHALL update the same service/check state model

