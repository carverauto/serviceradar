## Context
The platform already has enough bounded worker state to determine whether intervention is needed:
- current health state
- consecutive failures
- active probe outcomes
- recent probe history
- derived flapping
- failover success or exhaustion

What is missing is a supported threshold layer that promotes those states into explicit operator-facing alerts.

## Goals
- Evaluate alert thresholds from the existing authoritative worker model.
- Emit explicit alert-oriented signals for sustained degradation.
- Keep thresholds bounded and deterministic.
- Avoid duplicating health logic in a separate subsystem.

## Non-Goals
- Full alert routing, paging, or notification delivery.
- Unbounded worker history retention.
- A second health state machine independent of the worker registry.

## Proposed Approach
1. Add a small worker alert evaluator that derives thresholded alert states such as:
   - sustained unhealthy
   - flapping
   - failover exhausted / unavailable for capability dispatch
2. Evaluate those thresholds when worker state changes through probing or dispatch outcomes.
3. Emit transition-based telemetry or alert events when a threshold becomes active or clears.
4. Expose summarized alert state through the existing worker management surface.

## Initial Thresholds
- Unhealthy alert: consecutive failures at or above a bounded threshold.
- Flapping alert: derived flapping state is true.
- Exhaustion alert: capability-targeted selection or failover cannot find a healthy worker.

## Risks
- Operators may get noisy transitions if thresholds are too low.
- Alert semantics can drift if they are not tied directly to the authoritative worker model.

## Mitigations
- Start with conservative defaults.
- Emit only transition-based alert signals.
- Keep the raw worker health and probe context visible beside any summarized alert state.
