## ADDED Requirements

### Requirement: Discovery Schema Registry Binds Every Payload To An Identity Policy

The control plane SHALL maintain a registry mapping each discovery payload `schema` to the `source`
and `identity_source` it is ingested under, the identity policy class that must apply to it, and its
decoder. A schema whose declared policy class does not match what `SourcePolicy` actually decides for
that source SHALL fail the build. A schema whose source `SourcePolicy` does not classify SHALL fail
the build.

`SourcePolicy` recognises a source through two channels — the update's `source` **and** its
`metadata["identity_source"]`. The registry SHALL declare both, and the invariant SHALL be asserted
through each channel independently, because a downstream hop may rewrite one of them.

#### Scenario: A schema registered with a mismatched policy class fails the build

- **GIVEN** a schema registered with `policy_class: :enrichment_only`
- **WHEN** `SourcePolicy.enrichment_only_source?/1` returns false for its declared source
- **THEN** the build SHALL fail

#### Scenario: The invariant holds through the identity_source channel alone

- **GIVEN** a registered schema
- **WHEN** an update carries only `metadata["identity_source"]` and no `source`
- **THEN** `SourcePolicy` SHALL still reach the declared policy class

#### Scenario: An unregistered schema is dropped loudly

- **GIVEN** an add-on emits a discovery payload whose schema is not registered
- **WHEN** the control plane receives it
- **THEN** the payload SHALL be discarded
- **AND** a rate-limited warning and a telemetry event SHALL be emitted
- **AND** the payload SHALL NOT be silently accepted as healthy

### Requirement: Device Identity Is Constructed In The Control Plane, Not At The Edge

The control plane SHALL stamp every device identity field: `agent_id`, `gateway_id`, `partition`,
`source` and `identity_source`. `agent_id`, `gateway_id` and `partition` SHALL come from the
gateway-attested status metadata; `source` and `identity_source` SHALL come from the schema registry.
A value supplied by an add-on for any of these SHALL NOT reach device ingestion.

Discovery decoders SHALL emit observations only, and SHALL preserve `metadata["mac"]`, which the
MAC-anchoring guardrail reads.

#### Scenario: An add-on cannot claim a different source

- **GIVEN** a discovery payload whose body contains `source: "armis"`
- **WHEN** the control plane ingests it under a schema registered as `netprobe-mdns`
- **THEN** the resulting updates SHALL carry `source: "netprobe-mdns"`
- **AND** the enrichment-only policy SHALL apply

#### Scenario: An add-on cannot claim a different agent

- **GIVEN** a discovery payload whose body contains an `agent_id` other than the reporting agent's
- **WHEN** the control plane ingests it
- **THEN** the `agent_id` from the gateway-attested status metadata SHALL be used

#### Scenario: The MAC guardrail still applies after the translators move

- **GIVEN** a passive census observation of a locally administered MAC
- **WHEN** it is ingested through the discovery path
- **THEN** that MAC SHALL NOT anchor a canonical device
- **AND** the behavior SHALL be identical to the pre-migration agent-side translation

### Requirement: Chunked Discovery Snapshots Are Reassembled In The Control Plane

A discovery snapshot larger than one telemetry batch SHALL be split by the producer and reassembled
by the control plane. A partial snapshot SHALL NOT be ingested. Incomplete snapshot sets SHALL expire
on a bounded TTL and the number of concurrently buffered sets SHALL be bounded.

#### Scenario: A large segment's census is not silently dropped

- **GIVEN** a census snapshot that exceeds the single-batch size limit
- **WHEN** the producer splits it across parts
- **THEN** the control plane SHALL reassemble it and ingest the whole snapshot
- **AND** the snapshot SHALL NOT be discarded for exceeding the limit

#### Scenario: A snapshot that never completes is abandoned

- **GIVEN** a snapshot set whose remaining parts never arrive
- **WHEN** the buffering TTL elapses
- **THEN** the partial set SHALL be discarded and counted
- **AND** no partial observation SHALL reach device ingestion
