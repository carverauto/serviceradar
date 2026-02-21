## Context
Plugins should execute on edge agents against dynamic inventory subsets selected by operators. The control plane already owns SRQL execution and assignment distribution, so policy reconciliation belongs in core-elx/web-ng Ash domain with Oban scheduling.

Per-device plugin assignments are not viable for large camera fleets (for example 6,000+ cameras). The assignment model must support high cardinality while keeping agent config payloads and control-plane write volume bounded.

## Goals / Non-Goals
- Goals:
  - Dynamic, query-driven plugin targeting.
  - No plugin-side SRQL or control-plane API credentials.
  - Deterministic, idempotent assignment reconciliation.
  - Batched target delivery that scales to thousands of devices.
  - Safe operational controls (preview, limits, run-now).
- Non-Goals:
  - Running SRQL from plugin runtime.
  - Replacing existing direct assignment APIs (they remain supported).

## Architecture
1. Policy definition
- `PluginTargetPolicy` resource stores `target_query`, plugin package/version, cadence, timeout, params template, chunk size, and guardrails.

2. Reconciliation
- AshOban job (`PluginTargetPolicyReconciler`) runs on schedule.
- For each enabled policy:
  - execute SRQL query as system actor,
  - resolve each selected device to active agent/gateway,
  - group devices by agent,
  - chunk each group (`chunk_size`, bounded by `max_chunk_size`),
  - build desired assignment set keyed by `(policy_id, agent_id, chunk_index, chunk_hash)`,
  - upsert missing/changed assignments,
  - disable stale assignments.

3. Distribution
- Existing agent config path delivers policy-derived assignments.
- Each assignment includes a `targets[]` batch in params with device identifiers and plugin-relevant fields.

### Assignment `params_json` schema
Policy-derived assignments SHALL use a versioned payload contract:
- schema id: `serviceradar.plugin_target_batch_params.v1`
- canonical schema artifact:
  - `openspec/changes/add-plugin-targeting-policies/target-batch-params.schema.json`

Required top-level fields:
- `schema`
- `policy_id`
- `policy_version`
- `agent_id`
- `chunk_index`
- `chunk_total`
- `chunk_hash`
- `generated_at`
- `targets[]`

Target object requirements:
- required: `uid`
- optional: `ip`, `hostname`, `vendor`, `model`, `site`, `zone`, `labels`, `stream_hints[]`

Illustrative payload:
```json
{
  "schema": "serviceradar.plugin_target_batch_params.v1",
  "policy_id": "ptp_01J...",
  "policy_version": 7,
  "agent_id": "agent-123",
  "chunk_index": 0,
  "chunk_total": 12,
  "chunk_hash": "0e6c...<sha256>...",
  "generated_at": "2026-02-21T18:20:00Z",
  "template": {
    "timeout": "5s",
    "collect_events": true
  },
  "targets": [
    {
      "uid": "sr:device:abc",
      "ip": "10.20.1.10",
      "hostname": "axis-cam-01",
      "vendor": "AXIS",
      "stream_hints": [
        {
          "protocol": "rtsp",
          "endpoint": "rtsp://10.20.1.10/axis-media/media.amp",
          "auth_mode": "basic_or_digest"
        }
      ]
    }
  ]
}
```

4. Optional command bus fast-path
- command bus may trigger immediate reconcile or run-now.
- persisted reconciliation state remains owned by AshOban + policy resources.

## Data Model
`PluginTargetPolicy` (proposed fields):
- `id`
- `name`
- `plugin_package_id`
- `plugin_version`
- `target_query` (SRQL)
- `params_template_json`
- `interval_seconds`
- `timeout_seconds`
- `chunk_size` (default, e.g. 100)
- `max_targets`
- `enabled`
- `last_reconciled_at`
- `last_reconcile_summary`

Derived assignment metadata:
- `source = policy`
- `policy_id`
- `agent_id`
- `chunk_index`
- `target_count`
- `assignment_key` deterministic from `(policy_id, agent_id, chunk_index, chunk_hash)`

## Scaling Notes
- 6,000 targets with `chunk_size=100` yields ~60 assignments spread by agent, instead of 6,000 individual assignments.
- Reconcile writes are bounded by changed chunks, not changed devices.
- Agent-side execution can process target batches sequentially within plugin timeout/cadence settings.
- Recommended payload budget: `params_json` target 256KB soft limit, 1MB hard limit, always below runtime max payload constraints.

## Safety / Guardrails
- hard cap on matched targets per policy (`max_targets`)
- hard cap on `chunk_size` to respect assignment payload limits
- schema validation for every generated `params_json` payload
- chunk split/retry when payload budget exceeded
- preview endpoint before enable
- reconcile aborts on invalid SRQL with policy status update
- audit events for policy changes and reconcile outcomes

## Open Questions
- Should stale policy-derived assignments be disabled first and hard-deleted by retention job later?
- Should run-now execute one-shot plugin command bus action or just trigger immediate reconcile?
- Should batch assignment params include only identifiers (`uid`, `ip`) or richer cached camera metadata?
