## ADDED Requirements

### Requirement: Proxmox identity is scoped by immutable provider instance
The system SHALL assign each registered Proxmox integration an immutable
`provider_instance_ref` and SHALL include that reference in every Proxmox
cluster, host, guest, datastore, disk, NIC, storage, relationship, and console
target identity. The provider instance MUST NOT be derived solely from cluster
display name, node name, VMID, guest name, hostname, IP address, or browser input.

#### Scenario: Same node name exists in Farm and Tonka
- **GIVEN** Farm and Tonka are separate registered Proxmox provider instances
- **AND** each reports a node named `pve02`
- **WHEN** their enrichment is ingested
- **THEN** the system persists distinct instance-scoped host references and canonical relationships
- **AND** neither provider instance overwrites, aliases, reparents, or supplies a console target for the other

#### Scenario: Same guest identifier exists in two provider instances
- **GIVEN** two Proxmox provider instances report the same node name, guest type, and VMID
- **WHEN** their guest inventory is ingested
- **THEN** the scoped guest references, NICs, disks, parent hosts, and console targets remain distinct
- **AND** a query or console resolver constrained to one instance cannot return the other instance's row

#### Scenario: Cluster display name changes
- **GIVEN** a registered provider instance changes its cluster display name or rotates its credential
- **WHEN** its next authoritative enrichment is ingested
- **THEN** the immutable provider instance and existing scoped resource identities remain stable
- **AND** the new label or credential does not create a second provider identity

#### Scenario: Collector claims another provider instance
- **GIVEN** a trusted assignment is bound to one provider instance
- **WHEN** a collector result omits that instance or claims a different instance
- **THEN** ingestion rejects the result before changing virtualization resources or relationships
- **AND** it reports a sanitized assignment mismatch

### Requirement: Legacy unscoped Proxmox identity is migrated or quarantined
Before enforcing scoped uniqueness, the system SHALL classify legacy unscoped
Proxmox rows using trusted registration, assignment, source, and complete
relationship evidence. It SHALL transactionally migrate a row only when exactly
one provider instance is proven and SHALL quarantine zero-candidate,
multi-candidate, or conflicting rows from routing and authorization until
authoritative re-ingestion resolves them.

#### Scenario: Legacy row has one proven provider instance
- **GIVEN** trusted assignment and source evidence map a legacy Proxmox host and its dependents to exactly one provider instance
- **WHEN** the migration is applied
- **THEN** the host, guests, relationships, NICs, disks, datastores, and console targets are rewritten atomically into that instance namespace
- **AND** retrying the migration is idempotent

#### Scenario: Legacy node name is ambiguous across Farm and Tonka
- **GIVEN** a legacy `proxmox:node:pve02` row can belong to Farm or Tonka
- **AND** trusted evidence does not prove exactly one owner
- **WHEN** the migration classifies the row
- **THEN** it quarantines the row and its unsafe routing relationships rather than choosing by name, recency, or row order
- **AND** no terminal readiness, credential match, or session may use the quarantined identity

#### Scenario: Authoritative re-ingestion resolves quarantine
- **GIVEN** an ambiguous legacy row is quarantined
- **WHEN** each registered source re-ingests resources with its trusted provider instance
- **THEN** the system creates distinct scoped records and relationships from the new evidence
- **AND** removes quarantine only after scoped uniqueness and relationship validation pass

#### Scenario: Legacy alias is uniquely retained
- **GIVEN** a legacy reference is retained for bounded compatibility after migration
- **WHEN** it resolves inside exactly one provider instance
- **THEN** it may support an inventory read within that instance
- **AND** it MUST NOT authorize or route a console session

#### Scenario: Previously unique alias becomes ambiguous
- **GIVEN** a retained legacy alias gains a second provider-instance candidate
- **WHEN** compatibility resolution runs
- **THEN** the alias is disabled and the request fails closed
- **AND** the system does not preserve last-write-wins behavior

### Requirement: Proxmox guest parent relationships are console authoritative
The system SHALL link each active Proxmox guest provider record to exactly one
active parent PVE host in the same provider instance and SHALL treat that scoped
relationship as the only provider-terminal network upstream. A guest device MAY
remain the canonical display and audit target, but guest IP, hostname, metadata,
or its independently assigned route MUST NOT replace the parent PVE relationship.

#### Scenario: IP-less guest has an authoritative parent
- **GIVEN** a Proxmox LXC or QEMU guest has a scoped guest reference, type, VMID, and one active parent PVE
- **AND** it has no discovered guest IP
- **WHEN** terminal readiness is evaluated
- **THEN** the resolver may use the registered parent PVE endpoint and eligible parent route
- **AND** it does not invent or require a guest endpoint

#### Scenario: Guest has multiple active parents
- **GIVEN** a canonical guest maps to multiple active Proxmox parent hosts, provider references, types, or VMIDs
- **WHEN** terminal readiness is evaluated
- **THEN** readiness fails with sanitized reason `identity_ambiguous`
- **AND** the resolver does not choose the first, newest, or closest-named row

#### Scenario: Relationship crosses provider instances
- **GIVEN** a guest reference in Farm points to a parent host or route in Tonka
- **WHEN** the relationship is written or used
- **THEN** the system rejects the cross-instance relationship
- **AND** no console target, credential scope, or session is derived from it

#### Scenario: Guest moves to another PVE node
- **GIVEN** a provider reports a guest move with authoritative scoped evidence
- **WHEN** enrichment updates the guest parent relationship
- **THEN** the old parent relationship becomes ineligible for new terminal sessions
- **AND** readiness remains unavailable until the new parent endpoint and route are current
