# agent-connectivity Delta

## ADDED Requirements

### Requirement: Gateways receive the contract registry from core with the edge trust document
The agent gateway SHALL obtain the output-contract registry only from core. It SHALL
receive the registry in the same document as the edge trust snapshot over the
authenticated ERTS control plane. The document SHALL carry every non-retired
epoch with its state, snapshot digest, contract entries, signature, and signing
key id. Each contract entry SHALL carry its `projection_revision`. The gateway
SHALL verify every epoch's signature, over a preimage that includes each entry's
`projection_revision`, with the issuer public key the key id names before
installing the registry. It SHALL re-verify any
persisted or cached copy on load. When any epoch fails verification, the gateway
SHALL refuse that document's registry whole. It SHALL keep its previously
verified registry, and SHALL still install the document's trust. It SHALL
surface the refusal in an error log naming the epoch and key id, in a counter,
and in its next refresh report to core. A gateway that refused a candidate SHALL
NOT be counted as holding it. The gateway SHALL report the snapshot digests it
installed on its next refresh. The document SHALL also carry the set of bundle
digests that some live core node can project, and the gateway SHALL refuse a
record under any other bundle with a retryable refusal, never a rejection. The
gateway SHALL NOT read a registry from its
environment or from Helm values. A gateway with no verified registry, or whose
trust has expired, SHALL withhold records, never reject them.

#### Scenario: A gateway starts with no registry configuration
- **GIVEN** a gateway with no registry environment variable
- **WHEN** its first trust refresh from core succeeds
- **THEN** it holds the active epoch and any draining epochs
- **AND** its edge-records capability becomes ready

#### Scenario: A refresh carries a bad registry signature
- **GIVEN** a gateway holding a verified registry with epoch 1_000_000
- **WHEN** a refresh carries epoch 1_000_001 with a signature that does not verify
- **THEN** the gateway keeps admitting under its verified registry
- **AND** it does not install 1_000_001
- **AND** core's pipeline status names the gateway and the refused epoch
- **AND** core does not activate 1_000_001 while that gateway is live

#### Scenario: A fresh gateway receives only a bad registry
- **GIVEN** a gateway with no verified registry
- **WHEN** its first refresh carries a registry that fails verification
- **THEN** it withholds every record as `registry_unavailable`

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
