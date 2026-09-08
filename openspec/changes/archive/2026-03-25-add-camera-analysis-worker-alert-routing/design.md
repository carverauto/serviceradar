## Context
Camera analysis worker alert thresholds now exist as authoritative runtime state on registered workers. That state is already bounded, transition-based, and visible in the worker management surface. What is missing is promotion into the platform's existing observability model so the same worker degradation can appear in events, alerts, and downstream notification policy without inventing a second alerting subsystem.

## Goals / Non-Goals
- Goals:
  - Reuse the existing observability event and alert model for camera analysis worker degradation.
  - Emit activation and clear transitions with normalized worker metadata.
  - Avoid duplicate alerts from repeated probe failures or repeated dispatch failures while the derived worker alert state is unchanged.
  - Keep recovery behavior explicit so routed alerts clear when the worker alert state clears.
- Non-Goals:
  - New notification transports or paging integrations.
  - Replacing the worker ops surface with the observability UI.
  - Per-worker custom alert thresholds beyond the derived alert states already implemented.

## Decisions
- Decision: Treat worker alert transitions as observability events that can drive alerts through the existing platform model.
  - Alternatives considered:
    - Deliver notifications directly from the worker runtime: rejected because it bypasses the platform observability model.
    - Keep worker alert state only in telemetry and the worker UI: rejected because it does not participate in standard alert workflows.
- Decision: Emit only on alert-state transitions.
  - Alternatives considered:
    - Emit on every probe or dispatch failure: rejected because it would create duplicate routed alerts for stable degraded states.
- Decision: Include normalized worker, adapter, capability, and failover metadata in the routed signal.
  - Alternatives considered:
    - Minimal worker id only: rejected because operators need enough context to triage without correlating multiple sources manually.

## Risks / Trade-offs
- Risk: Worker alert routing could create noisy alerts if transition semantics drift from the derived worker state.
  - Mitigation: keep routing sourced only from authoritative alert-state transitions and add focused tests for no-op repeats.
- Risk: Clear transitions could fail to resolve routed alerts cleanly.
  - Mitigation: model both activation and clear transitions explicitly and test the recovery path.

## Migration Plan
1. Add normalized worker alert routing outputs in the runtime path where alert transitions already occur.
2. Translate those outputs into observability events and platform alerts.
3. Expose enough metadata in existing UI surfaces to cross-link worker ops and observability panes.

## Open Questions
- Whether routed worker alerts should use a dedicated event class or fit an existing degradation-oriented OCSF category.
