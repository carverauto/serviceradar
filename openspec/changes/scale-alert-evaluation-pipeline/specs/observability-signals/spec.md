## REMOVED Requirements

### Requirement: Durable bounded alert evaluation admission
**Reason**: Described admission into the CNPG evaluation inbox with per-rule and pending byte budgets that refuse load. Refusal fails the source batch and, after `max_deliver`, loses the evaluation. The inbox is removed.
**Migration**: Replaced by `alert-evaluation` "Partitioned candidate streams carry evaluation input" and "Evaluation backpressure is lag and never loss". Residual inbox rows are imported in order by the cutover ("Cutover from the CNPG inbox is ordered and complete").

### Requirement: Ordered replay-safe rule processing
**Reason**: Described per-rule ordering and replay safety through inbox positions, completion receipts and one transaction per occurrence.
**Migration**: Replaced by `alert-evaluation` "Evaluation state is deterministic and incrementally checkpointed", "Alert effects fire exactly once" and "Duplicate candidates are counted once". Ordering is per (rule, group key), whose candidates always share one partition; rule-wide operations (disable, delete, maintenance) are ordered markers on every partition.

### Requirement: Evaluation survives shard startup conflicts
**Reason**: Described the advisory-lock evaluation fence of the removed inbox owner.
**Migration**: Replaced by `alert-evaluation` "Leased partition ownership is fenced".

### Requirement: Alert evaluation telemetry uses JetStream
**Reason**: Described inbox queue depth, age and rejection metrics. The inbox no longer exists.
**Migration**: Replaced by `alert-evaluation` "Alert evaluation health and telemetry", which keeps JetStream publication and bounded labels.

### Requirement: Alert callers distinguish acceptance and completion
**Reason**: Described the inbox acceptance contract of `evaluate_logs/1`, `evaluate_events/1` and `evaluate_metrics/1`.
**Migration**: Acceptance is now a candidate publish acknowledgement ("Storage and routing complete before acknowledgement" in `telemetry-ingestion-capacity`). Completion-dependent callers keep waiting for the persisted alert. Maintenance keeps its synchronous count through `alert-evaluation` "Stale-anomaly maintenance keeps its synchronous count".
