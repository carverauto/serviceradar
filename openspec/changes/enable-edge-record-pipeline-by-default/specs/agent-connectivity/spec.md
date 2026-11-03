# agent-connectivity Delta

## ADDED Requirements

### Requirement: Gateways receive the contract registry from core with the edge trust document
The agent gateway SHALL obtain the output-contract registry only from core. It SHALL
receive the registry in the same document as the edge trust snapshot over the
authenticated ERTS control plane, and SHALL install trust and registry together
under one expiry. The document SHALL carry every non-retired epoch with its state,
snapshot digest, and contract entries. The gateway SHALL report the snapshot
digests it installed on its next refresh. The gateway SHALL NOT read a registry
from its environment or from Helm values. A registry it cannot parse or that has
expired SHALL make the gateway withhold records, never reject them.

#### Scenario: A gateway starts with no registry configuration
- **GIVEN** a gateway with no registry environment variable
- **WHEN** its first trust refresh from core succeeds
- **THEN** it holds the active epoch and any draining epochs
- **AND** its edge-records capability becomes ready

#### Scenario: The trust refresh stalls
- **WHEN** the gateway's last successful refresh is older than the snapshot expiry
- **THEN** it withholds new records rather than rejecting them
- **AND** admission resumes after the next successful refresh

### Requirement: Agents learn contract references only from their signed capabilities
An agent SHALL NOT load or compute the contract registry. It SHALL stamp each
record with the exact contract reference in the production capability it emits
under: a standing grant from its config, or a sweep lease. An agent SHALL move to a
new registry epoch only by receiving capabilities that core signed under that
epoch.

#### Scenario: A new epoch activates while an agent runs
- **GIVEN** an agent holding grants signed under epoch 1_000_000
- **WHEN** epoch 1_000_001 activates
- **THEN** the agent's next config poll returns grants signed under 1_000_001
- **AND** records it spooled earlier keep their 1_000_000 reference
