## Context
Camera analysis workers already have:
- authoritative health, flapping, and alert state in the worker registry
- routed observability events and alerts when that state changes
- duplicate suppression while the alert state is unchanged

What is still missing is the last mile into the standard notification-policy path. Without that, worker incidents appear in observability state but do not benefit from the same policy evaluation, cooldown, and re-notify handling used for other alerts.

## Goals / Non-Goals
- Goals:
  - Route camera analysis worker alerts through the existing notification-policy path.
  - Keep worker alerts subordinate to the standard observability alert lifecycle.
  - Preserve duplicate suppression and bounded re-notify semantics.
  - Expose enough policy-routing context for operators to understand whether a worker alert is notification-eligible.
- Non-Goals:
  - New notification transports.
  - A second worker-specific notification engine.
  - Replacing the existing observability alert model.

## Decisions
- Decision: notification policy integration will consume the existing routed worker alert records rather than direct worker health transitions.
  - This keeps worker notifications aligned with the same alert model used elsewhere.
- Decision: unchanged worker alert states remain duplicate-suppressed and rely on the standard alert re-notify path instead of emitting fresh worker-specific transitions.
  - This avoids notification spam and keeps semantics consistent with current alerting behavior.
- Decision: explicit operator visibility will be limited to policy-routing context and eligibility, not a full notification audit UI in this change.
  - The main value here is runtime integration, not a new notification-history surface.

## Risks / Trade-offs
- Worker alerts may enter notification policy more often than intended if routed alert classification is too broad.
  - Mitigation: keep routing tied to the bounded authoritative worker alert states that already exist.
- Re-notify behavior could duplicate worker alert transitions if the integration bypasses the current alert lifecycle.
  - Mitigation: integrate after routed alert creation, not before it.

## Migration Plan
1. Extend the routed worker alert path so those alerts are eligible for normal notification-policy evaluation.
2. Preserve duplicate suppression for unchanged worker alert state.
3. Expose policy-routing context in the worker ops API/UI.
4. Verify that sustained worker incidents re-notify through the standard path without generating duplicate routed alert transitions.
