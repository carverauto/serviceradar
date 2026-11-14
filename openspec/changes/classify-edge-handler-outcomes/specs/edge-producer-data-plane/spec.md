## ADDED Requirements

### Requirement: Edge record projection maps applied, settled, refused, and retryable outcomes consistently
`ServiceRadar.Edge.Projector` and `ServiceRadar.EventWriter.Processors.EdgeRecord` SHALL map projector outcomes across `publish/3` and `project/4` into four runtime dispositions without wrapping deterministic refusals in `RuntimeError`:

- `applied` (`:ok`) SHALL commit `platform.edge_delivery_slots` and `platform.event_ledger`, invoke `committed/3` for fresh primary deliveries, record `:projected` in `ServiceRadar.Edge.PipelineStats`, and acknowledge the broker delivery.
- `settled` (`{:settled, reason}`) SHALL commit `platform.edge_delivery_slots` and `platform.event_ledger`, invoke `committed/3` for fresh primary deliveries, record `:settled` in `ServiceRadar.Edge.PipelineStats`, and acknowledge the broker delivery on delivery 1 without dead-lettering.
- `refused` (`{:refused, reason_atom}` or `{:refused, {reason_atom, detail}}`) SHALL NOT commit `platform.edge_delivery_slots` or `platform.event_ledger`, SHALL record `:projector_refused` in `ServiceRadar.Edge.PipelineStats`, and SHALL fail the message with `ServiceRadar.EventWriter.EdgeRecordRefusedError` carrying `reason_atom` (or `{reason_atom, detail}`) so `ServiceRadar.EventWriter.EdgeRecordDeadLetter` dead-letters it on delivery 1 (`attempts=1`) with `Sr-Edge-Dlq-Reason` set to `Atom.to_string(reason_atom)`.
- `retryable` (`{:error, reason}` in `publish/3`, or a transaction rollback carrying a write failure in `project/4`) SHALL NOT commit `platform.edge_delivery_slots` or `platform.event_ledger`, SHALL record `:failed` in `ServiceRadar.Edge.PipelineStats`, and SHALL leave the message unacknowledged for JetStream backoff redelivery up to `dead_letter_after_deliveries`.

Projectors performing pre-projection control-plane lookups (including `Partition` and `Agent` capability lookups in `WasmPluginResult`) SHALL distinguish deterministic `NotFound` results (`refused`) from transient database or transport failures (`retryable`), and SHALL NOT coerce a transient database lookup error into an empty capability list or a permanent refusal.

#### Scenario: Settled projector outcome commits ledger and acknowledges on delivery 1
- **GIVEN** a fresh primary edge record whose projector returns `{:settled, {:stale_awx_membership_generation, detail}}`
- **WHEN** `Processors.EdgeRecord` processes the message
- **THEN** `platform.edge_delivery_slots` and `platform.event_ledger` SHALL record the delivery
- **AND** `PipelineStats` SHALL increment `:settled` for the record's contract
- **AND** the message SHALL be acknowledged on delivery 1 without publishing to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`

#### Scenario: Refused projector outcome dead-letters on delivery 1 under its specific reason atom
- **GIVEN** a fresh primary edge record on `TELEMETRY_EDGE_RECORD_V1_BULK` whose projector returns `{:refused, {:plugin_assignment_agent_mismatch, detail}}`
- **WHEN** `Processors.EdgeRecord` and `EdgeRecordDeadLetter` handle the failure
- **THEN** neither `platform.edge_delivery_slots` nor `platform.event_ledger` SHALL commit the record
- **AND** `EdgeRecordDeadLetter` SHALL copy the original record bytes and transport headers to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on delivery 1 (`Sr-Edge-Dlq-Attempts: "1"`)
- **AND** `Sr-Edge-Dlq-Reason` SHALL equal `"plugin_assignment_agent_mismatch"`, never `"RuntimeError"` or `"refused"`

#### Scenario: Transient agent or partition lookup error remains retryable
- **GIVEN** a fresh primary `serviceradar.plugin_results.batch` edge record arriving while CNPG times out on `Partition.get_by_id/2` or `Agent.get_by_uid/2`
- **WHEN** `WasmPluginResult.publish/3` runs
- **THEN** it SHALL return `{:error, reason}` (`retryable`) rather than substituting `[]` for `delivery_capabilities` or refusing the batch
- **AND** JetStream SHALL redeliver the record with backoff so a subsequent healthy attempt projects normally
