# Let a declarative check produce one verdict per query row

## Why

A declarative check can be bound to one of three target shapes: a single
target, a set of devices, or a set of service targets. Anything else a check
looks at has to be folded into one verdict.

Consider an invented estate with three hypervisor datastores. A check reads
the fullest one and compares it with a threshold. Datastore `tank01` crosses
90% and the check goes `down`; an alert opens. An hour later `tank02` crosses
90% as well. The check is already `down`, so nothing changes and nothing is
sent. When `tank01` is cleaned up the alert stays open, because `tank02` is
still full, and the operator is told nothing about either event. The alert also
cannot name the datastore, because the verdict belongs to the estate.

The same shape appears wherever the monitored things are rows of inventory that
are not devices: datastores, hypervisor guests seen through their runtime
state, storage volumes, certificates, recording policies, tunnels. Today each
needs either a hardcoded evaluator in Elixir or a plugin that emits its own
condition events, which is the hardcoding that Solution Packs exist to remove.

Repository context:

- `target_binding.mode` accepts `singleton`, `srql_devices` and
  `service_targets` (`DeclarativeChecks.SchemaValidator`).
  `DeclarativeChecks.Evaluation` fans `srql_devices` out in pages of 1,000 and
  prunes instances whose device left the scope.
- `VerdictEventWriter` already puts `target_key` on every transition event, and
  the rule core derives for a check groups by `check_slug` and `target_key`. A
  per-row target therefore gets its own alert with no change to alerting.
- A `srql_query` node runs one query per target. Fanning out over devices and
  querying each one's rows would cost one query per row; nothing lets the
  scope query's own rows be the data.
- Pruning deletes the instance of a departed target and marks its service state
  inactive, and emits no transition event. An alert that was open for that
  target stays open.

## What Changes

- **New target mode `srql_rows`.** `target_binding` names a read-only SRQL
  scope query and the row fields that identify a row. Each row the query
  returns becomes one target with its own instance, verdict, service state and
  alert. The scope query runs once per evaluation pass, however many rows it
  returns.
- **New core signal node `target_row`.** It outputs the current target's row,
  so `extract_field`, `threshold_assert` and `decision_table` judge the row the
  scope query already fetched. It is valid only in an `srql_rows` check.
- **Row fields in templates.** `{{target.row.<field>}}` and `{{target.label}}`
  join the existing `{{target.*}}` variables.
- **A named target in events and alerts.** The binding may declare a
  `label_template`. The label is stored on the instance and carried on the
  transition event, and the alert title and check results show it.
- **Departure closes the alert.** When a target with a non-healthy verdict
  leaves the scope, the pass emits a closing transition before it prunes the
  instance. This applies to every fan-out mode, and fixes the stale-alert gap
  that device fan-out has today. A target counts as departed only when a
  complete, successful, non-truncated scope read no longer contains it. The
  closing transition is delivered even for an inactive or out-of-service
  device, whose other events stay suppressed. It carries a
  `target_departed: true` marker that the alert engine treats as recovery-only,
  so it can close an alert but never open or renotify one.
- **A failed evaluation is not a departure.** A target still in scope whose
  graph evaluation fails keeps its instance and last status, publishes
  nothing, and is reported on the check as a pass diagnostic.
- **Bounds.** At most 1,000 row targets per check per pass. The scope is
  complete only when the page returned is short of the limit that ran; a full
  page is truncated, so the pass prunes nothing and closes no alert, and
  stored instances can exceed the bound until a later complete pass. Rows
  with a missing or
  duplicate key are not evaluated and are reported on the check, not dropped
  silently. Edge signal nodes and credential slots are refused in an
  `srql_rows` check.
- **Surfaces.** The pack format, the pack CLI validator, import and export, the
  check editor and Test Run, the OpenAPI document and
  `in:declarative_check_results` accept and show row targets.

Not in this change:

- Row targets for edge probes. A row is not something an agent can reach.
- Per-row parameter overrides or per-row alert silencing.
- Resolving `selector_query` for `service_targets` bindings. Until that
  lands, a binding with a selector and no `target_ids` evaluates nothing,
  prunes nothing and is reported on the check.
- Any Solution Pack content. The Proxmox Monitoring pack moves its datastore
  and paused-guest checks to row targets in its own change once this lands.

## Impact

- Affected spec: `declarative-service-checks` (one requirement modified, four
  added).
- Affected code: `ServiceRadar.DeclarativeChecks` (`SchemaValidator`,
  `Evaluation`, `DAGEngine`, `NodeEvaluators`, `DeclarativeCheckInstance`,
  `VerdictEventWriter`, `ServiceStateProjector`, `AlertRuleSync`, importer and
  exporter), the
  alert engine's event state machine
  (`ServiceRadar.Observability.StatefulAlertEngine.StateMachine`), which treats
  a `target_departed` event as recovery-only, one
  migration on `platform.declarative_check_instances`, the SRQL
  `declarative_check_results` entity, `js/cli` pack validation, and the web-ng
  check editor.
- Pending change `add-proxmox-host-outage-alerting`: its "Guest Paused By The
  Hypervisor" and "Node Storage Capacity Event" requirements describe per-guest
  and per-datastore plugin condition events. With row targets those two alerts
  come from the pack instead. If this change is approved, that change is
  revised to drop them; its guest-stopped and OOM-kill requirements are
  one-off events, not queryable state, and stay as they are.
- No behaviour change for existing checks, except two for `srql_devices` and
  `service_targets`: a departed device or service target with an open alert
  now has that alert closed, even when the device is out of service; and a
  target still in scope whose evaluation fails now keeps its instance and last
  status, where today its instance is deleted.
