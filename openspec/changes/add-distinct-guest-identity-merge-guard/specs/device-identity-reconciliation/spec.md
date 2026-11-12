## ADDED Requirements

### Requirement: Distinct Virtualization Guest Identities Never Merge Automatically
The system SHALL refuse every automatic merge of two device records that hold different virtualization guest identities, whatever the merge reason and whatever MAC, address, hostname or transitive evidence joins them.
A guest identity is a live `integration_id` identifier that names one hypervisor guest: a
Proxmox v3 guest reference `proxmox:v3:<integration>:<controller>:<cluster>:<qemu|lxc>:<vmid>`,
or a legacy Proxmox v2 guest reference `proxmox:v2:<cluster>:<vm|lxc>:<vmid>`. Two v3 references
that differ in any component, the VMID, kind, cluster, controller or integration, name different
guests. Node and cluster references are not guest identities.

The records hold different guest identities when, comparing v3 references with v3 references or
v2 references with v2 references, both hold at least one and neither record's set contains the
other's. A v2 reference SHALL NOT be compared with a v3 reference. A record holding no guest
identity, and a record whose guest identities the other record also holds, SHALL NOT be refused
by this rule. An identifier retired to the identifier archive SHALL NOT count as a guest identity.

The refusal SHALL be emitted as merge-guard telemetry with guard `distinct_guest_identity`,
logged, and recorded as a guard-block identity decision whose evidence names both records' guest
identities. A merge whose reason starts with `manual`, and an unmerge, SHALL NOT be refused by
this rule.

#### Scenario: A record holding other guests absorbs no guest with another VMID
- **GIVEN** a record holding the v3 references of guests 101 and 102 of a cluster
- **AND** a record holding the v3 reference of guest 136 of the same cluster
- **WHEN** hypervisor enrichment merges the second record into the first with reason `hypervisor_guest_network_match`
- **THEN** the merge SHALL be refused with guard `distinct_guest_identity`
- **AND** both records SHALL stay live with their own references
- **AND** the identity decision SHALL name both records' guest identities

#### Scenario: The scheduled reconciliation does not merge two guests over a shared MAC
- **GIVEN** two records joined by MAC evidence, one holding guest 136's reference and the other the references of guests 101 and 102
- **WHEN** the scheduled reconciliation attempts the merge with reason `identifier_backfill`
- **THEN** the merge SHALL be refused with guard `distinct_guest_identity`
- **AND** the next run SHALL skip the pair while its evidence is unchanged

#### Scenario: A guest seen again merges
- **GIVEN** two records holding the same guest reference, as a guest that migrated between nodes keeps its VMID and cluster
- **WHEN** an automatic merge of the two is attempted
- **THEN** this rule SHALL NOT refuse it

#### Scenario: A record without a guest identity merges into a guest
- **GIVEN** a guest record and an AWX host record or an agent's record holding no guest reference
- **WHEN** an automatic merge of the two is attempted
- **THEN** this rule SHALL NOT refuse it

#### Scenario: A retired guest reference does not block convergence
- **GIVEN** a record whose guest reference was retired to the identifier archive
- **AND** a record holding another guest's reference, such as the same VM re-created under a new VMID
- **WHEN** an automatic merge or a source succession of the two is attempted
- **THEN** this rule SHALL NOT refuse it

#### Scenario: An operator merge is not refused
- **GIVEN** two records holding different guest references
- **WHEN** an operator merges them with a reason starting with `manual`
- **THEN** the merge SHALL proceed
