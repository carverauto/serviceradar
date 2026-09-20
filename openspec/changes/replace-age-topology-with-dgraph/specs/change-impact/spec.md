## ADDED Requirements

### Requirement: Change records live in CNPG and project into Dgraph
The system SHALL persist network changes as Ash-backed `network_changes` rows and SHALL project each row into a Dgraph `Change` node with `change.affects` edges to the selected Device, Prefix, and Interface nodes.

#### Scenario: Prefix selector projects to Prefix
- **GIVEN** a proposed change whose selector includes CIDR `192.0.2.0/24`
- **WHEN** the change is stored
- **THEN** a `network_changes` row exists with that external id and window
- **AND** the Dgraph `Change` node `change.affects` the Prefix `192.0.2.0/24`

#### Scenario: Ticket text stays out of the graph
- **WHEN** a change with comments and a diff is stored
- **THEN** comments and diffs remain on the CNPG row or related audit tables
- **AND** the Dgraph node carries id, kind, window, status, source, and affects only

### Requirement: Downstream-of is a graph fact
The system SHALL expose a typed downstream-of query over canonical Dgraph topology after expanding Change selectors through Prefix membership, and SHALL NOT emit a postpone-or-sequence product verdict from that query.

#### Scenario: Downstream prefix is reachable
- **GIVEN** Change A affects prefix `192.0.2.0/24`
- **AND** Change B affects prefix `198.51.100.0/24`
- **AND** canonical topology has `198.51.100.0/24` downstream of `192.0.2.1`
- **WHEN** `downstream_of` runs from A's expanded devices to B's
- **THEN** the result is reachable
- **AND** no postpone/sequence recommendation is returned

#### Scenario: Disjoint topology is not reachable
- **GIVEN** two changes whose expanded device sets cannot reach each other on canonical topology
- **WHEN** `downstream_of` runs
- **THEN** the result is disjoint

### Requirement: Change-window verdicts belong to DeepCausality
The system SHALL treat postpone-or-sequence decisions as DeepCausality counterfactuals executed by scrith, consuming ServiceRadar's topology, Prefix, and Change projection as context.

#### Scenario: ServiceRadar does not own the verdict
- **WHEN** two overlapping-window changes are evaluated for operator action
- **THEN** the ordering verdict is produced by scrith + DeepCausality
- **AND** ServiceRadar supplies the hydrate-able graph and evidence only

### Requirement: Selectors expand through Prefix membership
The system SHALL expand a CIDR change selector to every Device that has an Interface linked to that Prefix before walking topology.

#### Scenario: Device in prefix is affected
- **GIVEN** a Device with an Interface that announces `192.0.2.0/24`
- **AND** a change that affects that Prefix
- **WHEN** the change's affected set is expanded
- **THEN** the Device is included
- **AND** expansion does not use only `ocsf_devices.ip << cidr`
