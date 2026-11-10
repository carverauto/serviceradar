# Change: Add the agent spool recovery coordinator

## Why

The agent spool detects corruption and resolves restarts totally over redundant commit evidence, and it holds a reserve for recovery. Nothing yet recovers a damaged segment: there is no coordinator that freezes, pages, journals and publishes a loss manifest, no attribution bound to each record, and no coverage proof that authorizes deleting a source segment. Until this lands, an ambiguous sequence gap wedges the sender lane and a corrupt segment is retained indefinitely.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

The Why section records the state when this change was split on 2026-11-02;
README.md records current implementation and validation status.

## What Changes

- Bind recovery attribution to each record at append time and keep it readable when the record segment is corrupt.
- Wire per-lane spool generations (`spool.LaneSet`) into the agent.
- Implement the bounded agent recovery coordinator from the frozen contracts, including construction-time coarsening rules.
- Delete a source segment only behind a durable coverage proof, and implement the recovery consumer and the durable assignment mapping it needs.

## Impact

- Affected specs: agent-connectivity, edge-producer-data-plane.
- Affected code: `go/pkg/edge/spool`, `go/pkg/edge/sender`, `go/pkg/edge/admission`, the EventWriter recovery consumer.
- Depends on: `unify-sweep-results-proto` (shared transport, spool, restart resolution).
