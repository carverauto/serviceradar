## ADDED Requirements

### Requirement: Edge record projection maps applied, settled, refused, and retryable outcomes consistently
`ServiceRadar.Edge.Projector` and `ServiceRadar.EventWriter.Processors.EdgeRecord` SHALL map projector outcomes across `publish/3` and `project/4` into four runtime dispositions without wrapping deterministic refusals in `RuntimeError`:

- `applied` (`:ok`) SHALL commit `platform.edge_delivery_slots` and `platform.event_ledger`, invoke `committed/3` for fresh primary deliveries, record `:projected` in `ServiceRadar.Edge.PipelineStats`, and acknowledge the broker delivery.
- `settled` (`{:settled, reason}`) SHALL commit `platform.edge_delivery_slots` and `platform.event_ledger`, invoke `committed/3` for fresh primary deliveries, record `:settled` (and SHALL NOT record `:projected`) in `ServiceRadar.Edge.PipelineStats`, and acknowledge the broker delivery on delivery 1 without dead-lettering.
- `refused` (`{:refused, reason_atom}` or `{:refused, {reason_atom, detail}}` from `publish/3` or `project/4`, or a `project/4` `{:error, reason}` for which `write_failure?/1` does not hold) SHALL NOT commit `platform.edge_delivery_slots` or `platform.event_ledger`, SHALL record `:projector_refused` in `ServiceRadar.Edge.PipelineStats`, and SHALL fail the message with `ServiceRadar.EventWriter.EdgeRecordRefusedError` carrying `reason_atom` (or `{reason_atom, detail}`) so `ServiceRadar.EventWriter.EdgeRecordDeadLetter` dead-letters it on delivery 1 (`attempts=1`) with `Sr-Edge-Dlq-Reason` set to `Atom.to_string(reason_atom)`.
- `retryable` (`{:error, reason}` in `publish/3`, or a `project/4` `{:error, reason}` for which `write_failure?/1` holds: an exception, Ash input or changeset, `Ash.BulkResult`, caught exit or throw, or a tuple or list containing one) SHALL NOT commit `platform.edge_delivery_slots` or `platform.event_ledger`, SHALL record `:failed` in `ServiceRadar.Edge.PipelineStats`, and SHALL leave the message unacknowledged for JetStream backoff redelivery up to `dead_letter_after_deliveries`.

`EdgeRecord` SHALL match explicit `{:settled, _}` and `{:refused, _}` returns before applying the `write_failure?/1` test to a `project/4` `{:error, reason}`. Recovery-control deliveries on `telemetry.edge-record-recovery.v1` SHALL NOT be dead-lettered: a `refused` recovery-control outcome SHALL retain its broker delivery as it does today and SHALL NOT be copied to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`.

Projectors performing pre-projection control-plane lookups (including `Partition` and `Agent` capability lookups in `WasmPluginResult`) SHALL distinguish deterministic `NotFound` results (`refused`) from transient database or transport failures (`retryable`), and SHALL NOT coerce a transient database lookup error into an empty capability list or a permanent refusal.

#### Scenario: Settled projector outcome commits ledger and acknowledges on delivery 1
- **GIVEN** a fresh primary edge record whose projector returns `{:settled, {:stale_awx_membership_generation, detail}}`
- **WHEN** `Processors.EdgeRecord` processes the message
- **THEN** `platform.edge_delivery_slots` and `platform.event_ledger` SHALL record the delivery
- **AND** `PipelineStats` SHALL increment `:settled` and SHALL NOT increment `:projected` for the record's contract
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

#### Scenario: Deterministic project/4 error stays refused
- **GIVEN** a fresh primary edge record whose `project/4` returns `{:error, :flow_attribution_partition_not_found}`
- **WHEN** `Processors.EdgeRecord` processes the message
- **THEN** the record SHALL be dead-lettered on delivery 1 with `Sr-Edge-Dlq-Reason: "flow_attribution_partition_not_found"`
- **AND** it SHALL NOT be redelivered for backoff retry

#### Scenario: Refused recovery control retains its delivery
- **GIVEN** a recovery-control delivery on `telemetry.edge-record-recovery.v1` whose projection is refused
- **WHEN** `Processors.EdgeRecord` handles the refusal
- **THEN** the broker delivery SHALL be retained
- **AND** nothing SHALL be published to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`
