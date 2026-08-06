## ADDED Requirements

### Requirement: Agent-forwarded k8s public endpoint inventory is admitted on the status path
The platform SHALL accept Kubernetes public endpoint inventory snapshots submitted by enrolled agents over the existing agent-gateway status RPCs (`PushStatus` / `StreamStatus`), using a reserved service type or source discriminator for this inventory kind. Admission SHALL apply gateway-attested agent identity and payload size limits consistent with other large edge results.

#### Scenario: Enrolled agent pushes inventory snapshot
- **WHEN** an enrolled agent submits a well-formed k8s public endpoint inventory status payload under the reserved discriminator
- **THEN** agent-gateway accepts the payload after mTLS authentication
- **AND** attaches or preserves tenant/partition/agent provenance from the authenticated session

#### Scenario: Oversized or unauthenticated inventory is rejected
- **WHEN** an inventory status payload exceeds configured size budgets or lacks valid agent authentication
- **THEN** the gateway rejects or fails closed without publishing partial untrusted ownership rows

### Requirement: Gateway publishes agent-forwarded inventory onto the existing JetStream subject family
After admission, agent-gateway SHALL publish inventory snapshot bytes to the same JetStream subject family used by co-located collectors (`inventory.k8s.public_endpoints` / stream `k8s_inventory` or the configured equivalent) so core EventWriter processors remain the single write path into `public_endpoints_current`.

#### Scenario: Agent path and NATS path converge in core
- **WHEN** inventory arrives via agent-gateway publish to JetStream
- **THEN** the existing core public endpoint inventory processor can upsert ownership rows
- **AND** SRQL `in:public_endpoints` and attributed-flow VIP joins consume those rows without a second storage path

#### Scenario: Direct NATS co-located path remains valid
- **WHEN** inventory is published directly to JetStream from an in-cluster collector
- **THEN** gateway agent routing is not required for that install
- **AND** core ingest behavior remains equivalent for ownership fields
