## ADDED Requirements

### Requirement: Proxmox virtualization identities are source and cluster scoped
The system SHALL identify every Proxmox provider instance and virtualization object with a versioned `proxmox:v3` identity containing immutable ServiceRadar integration ID, immutable controller ID, normalized native cluster ID, object kind, and native object ID. Display names, hostnames, URLs, IPs, node names, and VMIDs SHALL NOT be globally authoritative outside that source and cluster scope.

#### Scenario: Two integrations discover identical native identifiers
- **GIVEN** farm01 and tonka01 are separate Proxmox integration/controller scopes
- **AND** both report the same cluster display name, node name, and QEMU VMID
- **WHEN** inventory reconciliation writes their provider instances, nodes, and guests
- **THEN** each object SHALL have a distinct v3 identity because its integration/controller scope differs
- **AND** neither source SHALL update, merge, alias, or overwrite the other source's object

#### Scenario: QEMU and LXC share a numeric VMID
- **GIVEN** one cluster reports a QEMU guest and an LXC guest with the same numeric VMID
- **WHEN** identities are rendered
- **THEN** the object kind SHALL make the identities distinct
- **AND** relationships and console capabilities SHALL remain attached to the correct guest type

#### Scenario: Display metadata changes
- **GIVEN** a PVE hostname, cluster display name, controller URL, or guest name changes without changing the immutable source and native object identity
- **WHEN** inventory is reconciled
- **THEN** the existing v3 object SHALL be updated in place
- **AND** the display change SHALL NOT create a cross-source alias or change credential ownership

### Requirement: Virtualization writes cannot cross provider-source boundaries
The inventory writer SHALL enforce uniqueness and ownership using the structured v3 identity fields. It SHALL reject an upsert or relationship update that omits source scope, uses an authoritative legacy identity, or would transfer an object between integrations/controllers without an explicit audited migration.

#### Scenario: Upsert uses another controller's provider reference
- **GIVEN** a guest belongs to one integration/controller source
- **WHEN** another source attempts to upsert the same rendered cluster name, node, kind, and VMID using its own sync
- **THEN** the writer SHALL create or update only the second source's distinct v3 object
- **AND** it SHALL preserve the first source's device link, owner relationship, and console metadata

#### Scenario: Payload omits immutable source scope
- **GIVEN** a Proxmox discovery payload has a cluster/name/VMID identity but no compatible integration and controller binding
- **WHEN** the writer validates it
- **THEN** authenticated enrichment SHALL be rejected or quarantined
- **AND** the writer SHALL NOT infer the source from a matching display name, IP, URL, or existing legacy row

### Requirement: Legacy Proxmox identities are non-authoritative aliases
The migration SHALL map each legacy v1/v2 Proxmox reference to a v3 identity only when producing integration/controller provenance makes the mapping one-to-one. Legacy aliases SHALL be read-only and SHALL NOT authorize writes, credential resolution, ownership selection, or console routing.

#### Scenario: Legacy reference maps unambiguously
- **GIVEN** a legacy provider reference has exactly one source-proven v3 target
- **WHEN** an existing read path resolves the legacy reference during the compatibility period
- **THEN** it MAY return the v3 object through a read-only alias
- **AND** all new writes and relationships SHALL use the v3 identity

#### Scenario: Legacy reference is ambiguous across clusters
- **GIVEN** the same legacy cluster/name/VMID reference could identify objects in farm01 and tonka01
- **WHEN** migration or lookup evaluates the reference
- **THEN** the alias SHALL be quarantined as ambiguous
- **AND** no object merge, credential resolution, current-owner selection, or console session SHALL occur from that alias

#### Scenario: Migration is replayed
- **GIVEN** v3 backfill and relationship migration completed once
- **WHEN** the migration is rerun after another inventory sync
- **THEN** it SHALL be idempotent
- **AND** counts, source ownership, device links, and unambiguous aliases SHALL remain stable

### Requirement: Guest ownership identifies an exact current PVE controller and node
Each Proxmox guest eligible for native console access SHALL have one unambiguous current-owner relationship to its v3 provider instance, integration, controller, native cluster, and PVE node. The authoritative controller base origin SHALL be host-owned integration state, not guest network metadata.

#### Scenario: Guest is discovered on owner node
- **GIVEN** authenticated inventory reports a guest on a PVE node
- **WHEN** the guest and relationships are reconciled
- **THEN** the current-owner relationship SHALL bind the guest to the exact v3 node and controller source
- **AND** the guest IP SHALL remain non-authoritative inventory metadata

#### Scenario: Guest migrates between nodes
- **GIVEN** a guest moves to another node inside the same source-scoped cluster
- **WHEN** authoritative inventory confirms the move
- **THEN** reconciliation SHALL atomically update the current-owner relationship
- **AND** a console session bound to the prior owner SHALL fail revalidation instead of silently switching nodes

#### Scenario: Owner is missing or duplicated
- **GIVEN** a guest has zero or multiple current-owner relationships
- **WHEN** native console availability is evaluated
- **THEN** the console SHALL be unavailable
- **AND** no controller or node SHALL be guessed from guest IP, hostname, VMID, display cluster name, or another integration
