## ADDED Requirements

### Requirement: Proxmox Wasm uses non-secret semantic inventory operations
The first-party Proxmox Wasm plugin SHALL request only manifest-declared semantic inventory operations and SHALL NOT receive or construct privileged authentication, controller targets, or arbitrary credential-bearing HTTP requests.

#### Scenario: Plugin gathers authenticated inventory
- **GIVEN** the host-only assignment authorizes a bounded set of inventory operations for one v3 provider instance
- **WHEN** the plugin gathers cluster, node, and guest information
- **THEN** it SHALL request semantic operations using non-secret selectors
- **AND** the trusted agent connector SHALL select the controller target and apply the credential
- **AND** the plugin result SHALL contain no token, secret reference, broker grant, protected header, ticket, cookie, or CSRF value

#### Scenario: Plugin attempts target substitution
- **GIVEN** the plugin is assigned to one Proxmox integration/controller
- **WHEN** it supplies a different base URL, scheme, port, host, address, node, cluster, VMID, header, TLS policy, redirect, path, query, or privileged body
- **THEN** the host SHALL reject the operation before credential resolution or dial
- **AND** the plugin SHALL receive a bounded policy-denied result

### Requirement: Proxmox discovery emits source-scoped identity evidence
Authenticated Proxmox discovery SHALL emit the non-secret source and native identity fields required to construct v3 provider-instance, node, and guest identities and exact current-owner relationships. The inventory writer, not plugin display data, remains authoritative for ServiceRadar integration/controller IDs.

#### Scenario: Cluster with node and guests is discovered
- **GIVEN** one registered Proxmox integration/controller returns a cluster, PVE node, QEMU guest, and LXC guest
- **WHEN** discovery results are normalized
- **THEN** every object SHALL carry the assignment's immutable integration/controller scope, normalized native cluster identity, object kind, native object ID, and owning node evidence
- **AND** the writer SHALL render and persist v3 identities without using cluster or node display names as global keys

#### Scenario: Two assignments report identical names and VMIDs
- **GIVEN** farm01 and tonka01 assignments return identical cluster names, node names, and VMIDs
- **WHEN** the plugin results are ingested
- **THEN** each result SHALL remain bound to its producing assignment and integration/controller
- **AND** batching, retries, streaming, and deduplication SHALL NOT collapse objects across those scopes

### Requirement: Proxmox plugin observability is credential-free
Proxmox plugin status, details, telemetry, discovery payloads, events, logs, errors, and diagnostics SHALL exclude raw or redeemable credential data and protected connector state.

#### Scenario: Provider rejects an authenticated request
- **GIVEN** the trusted connector receives a Proxmox error that contains a token, ticket, cookie, CSRF value, protected request field, or privileged response body
- **WHEN** the plugin receives the semantic failure
- **THEN** it SHALL receive only a bounded phase, safe reason code, and correlation ID
- **AND** plugin output SHALL not include the provider error body or protected connector state

#### Scenario: Plugin memory and calls are inspected
- **GIVEN** test credentials contain unique sentinel values
- **WHEN** the inventory and console plugin paths execute
- **THEN** sentinel values and redeemable references SHALL be absent from Wasm configuration, host-call inputs/results, linear memory snapshots, logs, and emitted data
- **AND** the test SHALL fail if any sentinel or protected-field derivative is observed
