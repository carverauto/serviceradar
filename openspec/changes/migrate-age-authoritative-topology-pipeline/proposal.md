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
- Add a one-time graph reset/rebuild workflow that can clear polluted topology evidence and regenerate AGE edges from fresh observations.
- Make web topology rendering AGE-driven and unresolved-node tolerant (render unresolved endpoints explicitly instead of guessing).
- Add migration telemetry gates (direct/inferred ratio, unresolved endpoint counts, edge churn) for rollout and rollback decisions.

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
