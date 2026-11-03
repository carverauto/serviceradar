# Change: Add producer run lifecycles and inventory completeness

## Why

Inventory producers get typed batch contracts in `move-agent-telemetry-to-edge-records`, and leased sweeps complete at the plan's target count. No producer emits start, checkpoint or terminal evidence, so an inventory run cannot prove it was complete, and absence or deletion cannot be applied safely.

Split out of `unify-sweep-results-proto` on 2026-11-02, when that change's task list was reconciled against `staging`. The requirements and tasks below moved verbatim; none of them blocks shipping the durable edge pipeline or archiving `unify-sweep-results-proto`.

## What Changes

- Define run start, checkpoint and complete/partial/aborted terminal evidence with a bounded consistency proof.
- Emit execution lifecycle evidence from the agent's sweep and inventory producers.
- Project inventory pages through a DIRE-aware projector that applies absence only after a valid complete terminal.

## Impact

- Affected specs: edge-producer-data-plane.
- Affected code: `proto/edge/v1`, the agent inventory producers, EventWriter inventory projectors.
- Depends on: `unify-sweep-results-proto` and `move-agent-telemetry-to-edge-records` task 7.2.
