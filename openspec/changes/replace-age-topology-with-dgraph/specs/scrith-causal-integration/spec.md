## ADDED Requirements

### Requirement: Scrith is the generalized reasoner
The system SHALL treat scrith as a generalized ontology, causal-reasoning, and knowledge-graph core (DeepBrain plus the intelligence layer), with ServiceRadar as the reference NMS plugin into the enterprise integration / extension layer rather than as the only consumer.

#### Scenario: ServiceRadar does not own the verdict
- **WHEN** an operator needs a reliability, security, or change-ordering verdict
- **THEN** that verdict is produced by scrith core + DeepCausality
- **AND** ServiceRadar supplies evidence, topology, and an NMS-plugin snapshot only

#### Scenario: Other NMS can implement the same plugin
- **WHEN** the extension contract is specified
- **THEN** it is named in NMS-neutral terms (assets, links, prefixes, changes, telemetry)
- **AND** it sits in scrith's enterprise integration / extension layer (CXP-shaped)
- **AND** ServiceRadar is documented as the reference implementation, not the only one

#### Scenario: In-flight ServiceRadar engine is not assumed
- **GIVEN** `add-causal-engine` may be scrapped
- **WHEN** this change is implemented
- **THEN** nothing in the Dgraph cutover depends on a ServiceRadar `rust/causal-engine` process
- **AND** God View remains a renderer of topology and of verdicts it is given

### Requirement: Separate Dgraph instances
ServiceRadar and scrith SHALL each operate their own Dgraph cluster. They SHALL NOT share an instance, and they SHALL NOT join data across Dgraph namespaces.

#### Scenario: No shared cluster
- **WHEN** ServiceRadar projects topology
- **THEN** it writes only to the ServiceRadar Dgraph
- **AND** scrith does not mount that cluster

#### Scenario: Namespaces are not a cross-product join
- **GIVEN** Dgraph namespaces cannot be queried across
- **WHEN** scrith needs NMS topology
- **THEN** it receives a plugin snapshot over the network
- **AND** it does not issue a DQL query against a ServiceRadar namespace

### Requirement: NMS extension snapshot is the seam
The system SHALL expose a network snapshot that implements scrith's NMS extension contract: assets, links, prefixes, proposed changes, and a bounded telemetry/status set, sufficient for scrith to copy a subgraph into its own ontology or Dgraph.

#### Scenario: Snapshot is NMS-neutral
- **WHEN** the hydrate/snapshot API is called for a change window
- **THEN** the payload includes Device, Interface, Prefix, TopologyEdge, and Change nodes in the affected neighbourhood
- **AND** it includes status, capacity, and telemetry for those devices
- **AND** it is readable without access to the NMS Dgraph gRPC port
- **AND** field names in the contract are not ServiceRadar crate paths

### Requirement: ChangeImpact contract is frozen, not implemented here
The system SHALL document a ChangeImpact RPC on scrith core that accepts two change identifiers against a plugin snapshot and returns a DeepCausality verdict with an effect log, and this ServiceRadar change SHALL NOT implement that RPC.

#### Scenario: Contract lives on scrith
- **WHEN** the integration contract is reviewed
- **THEN** the RPC is specified as a scrith-core service
- **AND** no ServiceRadar crate implements it in this change
- **AND** issues for the extension layer, RPC, causaloids, and Ethos are filed on the scrith repository

### Requirement: Ethos governs starting a downstream change
Scrith SHALL apply DeepCausality Ethos Teloids to a proposed start of change B while change A occupies the same window, using downstream-of as context rather than as the verdict.

#### Scenario: Availability-impacting upstream makes B impermissible
- **GIVEN** Change A is kind `upgrade` and B is downstream of A
- **AND** the windows overlap
- **WHEN** Ethos evaluates starting B
- **THEN** the Teloid marks starting B Impermissible (delay) with a logged justification
- **AND** that evaluation is out of scope for this ServiceRadar change
