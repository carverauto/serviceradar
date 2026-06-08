## ADDED Requirements

### Requirement: Agent-routed add-on telemetry
The ingestion pipeline SHALL route native add-on telemetry from the agent through agent-gateway/core over the existing authenticated status path, reusing the same gateway-attested tenant routing as other agent-submitted telemetry. The agent SHALL forward add-on telemetry on the existing `StreamStatus` RPC using a reserved `source` discriminator (`addon:<addon_id>`) rather than a new gateway RPC. Core SHALL attach or validate partition, gateway, agent, source host, and runtime metadata from the authenticated mTLS envelope before publishing or writing normalized observability records.

#### Scenario: Gateway-attested identity overrides add-on-supplied identity
- **GIVEN** a native add-on telemetry payload includes local source metadata
- **WHEN** the agent-gateway receives the telemetry from an authenticated agent connection
- **THEN** core SHALL use gateway-attested partition, gateway, and agent identity (derived from the mTLS certificate) for tenant scoping
- **AND** add-on-supplied identity fields SHALL be treated as source metadata only

#### Scenario: Add-on OCSF event reaches db-event-writer
- **GIVEN** a native add-on emits a telemetry batch with payload kind `ocsf_event`
- **WHEN** the agent forwards the batch through gateway/core with source `addon:<addon_id>`
- **THEN** core SHALL publish the event to the registered NATS subject consumed by db-event-writer
- **AND** db-event-writer SHALL persist the event to the OCSF event store without requiring an OTEL collector hop

### Requirement: Add-on telemetry supports idempotent batches
The ingestion pipeline SHALL preserve add-on-provided event identities or idempotency keys so retries do not create duplicate OCSF event rows, relying on the OCSF event store's conflict handling (`ON CONFLICT (id, time) DO NOTHING`).

#### Scenario: Gateway retry does not duplicate event
- **GIVEN** an add-on telemetry batch is retried after a transient gateway or downstream failure
- **WHEN** the same event identity is received more than once
- **THEN** persistence SHALL de-duplicate the event via the target table's `(id, time)` conflict handling
- **AND** retry counters SHALL remain observable
