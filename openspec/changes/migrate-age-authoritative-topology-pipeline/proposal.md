# Change: Migrate topology to an AGE-authoritative evidence pipeline

## Why
Topology output is still unstable in live runs (islands, missing uplinks, overlinked clusters) even after mapper and UI patches. Recent runs show high inferred-link volume, sparse direct links, and repeated UniFi payload shape drift. Today, identity, inference, and rendering heuristics are spread across mapper, ingestion, AGE projection, and UI stream logic, so bad evidence can amplify into persistent graph pollution.

We need a single authoritative topology path where:
1. mapper emits evidence only,
2. core reconciles evidence into canonical identity and adjacency,
3. AGE stores the definitive graph,
4. web rendering consumes AGE topology without identity guessing.

## What Changes
- Introduce an evidence-first topology contract for mapper output (typed observation envelope with explicit source confidence and raw keys captured for drift diagnostics).
- Enforce immutable source endpoint IDs in topology observations and prohibit UI-layer identifier fusion.
- Add deterministic reconciliation in core that derives canonical `CONNECTS_TO` edges in AGE from evidence, with stale-edge expiry.
- Add SNMP flood/trunk suppression rules so high-fanout bridge ports do not generate false direct links.
- Add source parser contract adapters/tests and drift quarantine behavior so shape drift fails loudly instead of silently degrading topology.
- Add a one-time graph reset/rebuild workflow that can clear polluted topology evidence and regenerate AGE edges from fresh observations.
- Make web topology rendering AGE-driven and unresolved-node tolerant (render unresolved endpoints explicitly instead of guessing).
- Enforce strict graph class policy: physical view defaults to direct L2 evidence; inferred edges remain separately classified and toggleable.
- Add migration telemetry gates (direct/inferred ratio, unresolved endpoint counts, edge churn) for rollout and rollback decisions.

## Phased Execution Plan
1. Separate planes
- Identity plane: immutable device IDs.
- Evidence plane: append-only observations with provenance.
- Topology plane: deterministic graph build from evidence rules.

2. Evidence-first ingestion
- Store normalized observations per source.
- Prohibit direct node merges from topology edges.

3. Single reconciler authority
- One reconciler pass builds canonical devices/links.
- Emit diagnostics explaining acceptance/rejection of each edge.

4. Source contracts and drift guards
- Versioned source adapters.
- Fixture-based contract tests from real controller payloads.
- Quarantine drifted source payloads.

5. Strict graph policy
- Physical view shows direct evidence by default.
- Inferred edges stay separate/toggleable.
- Unresolved references remain explicit unresolved nodes.

6. Operational observability
- Per-run report includes source counts, observations by type, accepted/rejected edges with reasons, and unresolved IDs.

## Impact
- Affected specs:
  - `network-discovery`
  - `device-identity-reconciliation`
  - `age-graph`
- Affected code (expected):
  - `pkg/mapper/discovery.go`
  - `pkg/mapper/snmp_polling.go`
  - `pkg/mapper/types.go`
  - mapper payload/streaming contracts
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/topology/topology_graph.ex`
  - `web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - migration/reset scripts for topology evidence and AGE projection tables
