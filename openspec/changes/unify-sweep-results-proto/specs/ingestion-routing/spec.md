# ingestion-routing

## ADDED Requirements

### Requirement: Sweep results are delivered as native protobuf
Sweep host results SHALL be delivered from the agent to core as a native
protobuf message (`SweepResultBatch` of `SweepHostResult`), not as JSON encoded
inside an opaque bytes field.

#### Scenario: Agent emits proto sweep results
- **WHEN** an agent completes a sweep
- **THEN** it SHALL emit the host results as a protobuf `SweepResultBatch`,
  carrying per-host ICMP status, TCP port results, and (when MTR ran) the full
  MTR trace, without JSON-encoding the per-host payload

#### Scenario: Core decodes proto once and fans out
- **WHEN** core receives a `SweepResultBatch`
- **THEN** it SHALL decode it once and persist reachability/ports to the sweep
  results store and any MTR trace to the MTR traces store from the same decoded
  message, without a second delivery pipeline for the trace

### Requirement: One message carries a host's full multi-mode result
A single `SweepHostResult` SHALL carry a host's ICMP, TCP, and MTR results
together; a logical result SHALL NOT be split across multiple delivery
pipelines.

#### Scenario: Mixed-mode host in one message
- **WHEN** a host was scanned with ICMP, TCP, and MTR in one sweep
- **THEN** its ICMP status, TCP port results, and full MTR trace SHALL travel in
  a single `SweepHostResult` message

### Requirement: Backward-compatible rollout across independently-deployed agents
During the migration, core SHALL accept both the legacy JSON sweep format and
the new protobuf format, distinguished by an explicit format marker rather than
content sniffing, so a mixed fleet loses no results.

#### Scenario: Mixed fleet during rollout
- **WHEN** some agents emit legacy JSON sweep results and others emit protobuf
- **THEN** core SHALL route each to the correct decoder by its explicit format
  marker and persist both without loss

#### Scenario: JSON removed after rollout
- **WHEN** no agent in the fleet emits the legacy JSON format
- **THEN** the JSON emit and decode paths MAY be removed in a subsequent release
