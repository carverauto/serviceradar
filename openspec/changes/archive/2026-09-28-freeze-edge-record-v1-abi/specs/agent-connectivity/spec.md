## ADDED Requirements

### Requirement: Capability is advertised in Hello and the lane is negotiated in lane-open
Capability SHALL be advertised in `Hello` and a lane's parameters SHALL be negotiated in lane-open, and neither SHALL be inferred from configuration or a binary version.

`Hello` SHALL be the CAPABILITY authority: the edge-record protocol, the supported
platform payload families, encodings, and compression, the durable spool-reader
versions, the frame bounds, and the output-contract registry epoch and digest SHALL
be advertised there as TYPED fields.

`EdgeRecordCapabilitiesV1` in `proto/edge/v1/record.proto` is the typed
advertisement. Its wire fields and enum numbers are authoritative there. It is
carried as `edge_record_capabilities` on both Hello messages. An absent carrier
advertises no edge-record support; the legacy string list SHALL NOT supply it.

`EdgeRecordLaneOpen` / `EdgeRecordLaneOpenAck` are the authority for the LANE
PARAMETERS THEY CARRY, and only those: route profile, traffic class, spool
identity, sequence base, first unresolved sequence, session nonce, and the credit
grant. They SHALL NOT be described as governing contracts, encodings, compression,
or frame bounds -- those fields are not in the message, so a rule making lane-open
"win" over `Hello` for them would be unimplementable. An earlier revision of this
requirement asserted exactly that.

A peer SHALL NOT infer a format, contract, encoder, or bound from configuration
content, a config hash, or a binary version number.

The lane messages are frozen in `proto/edge/v1/record.proto`. The Hello capability
fields are a DIFFERENT carrier: a shared typed `EdgeRecordCapabilitiesV1` defined in
`proto/edge/v1/record.proto` and IMPORTED into BOTH `AgentHelloRequest` and
`ControlStreamHello` in `proto/monitoring.proto`, which are the two agent hellos
that exist. Where both appear in one session they SHALL be equal as sets,
and a difference SHALL be rejected as a capability conflict. Every repeated field
is an unordered set; duplicate members SHALL be refused even when both Hellos
carry the same duplicates. Scalar bounds, registry epoch and snapshot digest
SHALL match exactly. Absence and a present carrier SHALL NOT compare equal.

The advertisement SHALL list supported output contracts explicitly. Each member
is the exact tuple `(contract_id, contract_version, contract_bundle_sha256)` under
the advertised registry epoch and snapshot digest. Registry identity alone SHALL
NOT imply support for every contract in that registry. These members advertise
support, not execution permission; they carry no effective grant or signature.

The comparison API operates on decoded advertisements. Raw Hello limits,
authenticated session association, negotiation and grant enforcement belong to
the runtime integration; the presence of the carrier and comparison API SHALL NOT
be represented as live enforcement on either RPC.

#### Scenario: Order-independent agreement
- **WHEN** both Hello messages advertise the same members in different orders
- **AND** every scalar and contract tuple agrees
- **THEN** the advertisements SHALL compare equal

#### Scenario: Duplicated capability
- **WHEN** either advertisement repeats a member in any capability set
- **THEN** comparison SHALL refuse the duplicate rather than silently deduplicating it
- **AND** the same duplicates in both advertisements SHALL still be refused


#### Scenario: Capability is read from Hello, not inferred
- **WHEN** a peer needs a supported contract, encoding, compression, or frame bound
- **THEN** it SHALL read the value advertised in `Hello`
- **AND** SHALL NOT infer it from a config content hash or a binary version

#### Scenario: Lane parameters are read from lane-open
- **WHEN** a lane is opened
- **THEN** its route profile, traffic class, spool identity, sequence base, nonce,
  and credits SHALL be the negotiated lane-open values

#### Scenario: An unadvertised contract is requested
- **WHEN** a run requests an output contract or encoding the agent did not
  advertise under the required registry epoch
- **THEN** the request SHALL fail with an explicit capability error
