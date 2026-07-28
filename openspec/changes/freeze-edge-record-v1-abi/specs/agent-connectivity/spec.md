## ADDED Requirements

### Requirement: Capability is advertised in Hello and the lane is negotiated in lane-open
Capability SHALL be advertised in `Hello` and a lane's parameters SHALL be negotiated in lane-open, and neither SHALL be inferred from configuration or a binary version.

`Hello` SHALL be the CAPABILITY authority: the edge-record protocol, the supported
platform payload families, encodings, and compression, the durable spool-reader
versions, the frame bounds, and the output-contract registry epoch and digest SHALL
be advertised there as TYPED fields.

Those fields DO NOT EXIST in today's `monitoring.proto` Hello messages. Adding them
is a deliverable of task 1.1 and a PREREQUISITE of the 1.7 freeze; until they land
this requirement describes a target, and no component SHALL be said to read a typed
capability from a message that has no such field. An earlier revision asserted the
advertisement as though the fields were already there -- the same error as claiming
lane-open governs values it does not carry.

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
that exist. Where both appear in one session they SHALL be equal, and a difference
SHALL be rejected as a capability conflict. Neither carries them today; task 1.1
adds them and the 1.7 freeze waits on it.

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
