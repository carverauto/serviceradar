## Context
Camera analysis worker alerts now:
- produce authoritative routed observability alerts
- participate in standard notification-policy eligibility
- remain duplicate-suppressed while unchanged

What is still missing is operator-facing audit visibility into actual notification lifecycle state. The standard alert model already tracks fields like `notification_count` and `last_notification_at`, but the worker ops surface does not expose them, so operators cannot tell whether a worker alert is merely eligible or has already notified.

## Goals / Non-Goals
- Goals:
  - Expose notification audit state for active routed worker alerts.
  - Reuse the existing standard alert lifecycle as the source of truth.
  - Keep the worker ops surface bounded and focused on current routed alert delivery state.
- Non-Goals:
  - New notification transports.
  - A full historical notification timeline or delivery log browser.
  - A worker-specific notification store.

## Decisions
- Decision: audit visibility will read from the existing routed `Monitoring.Alert` record keyed by routed alert source id.
  - This keeps all delivery state anchored to the standard alert lifecycle.
- Decision: the worker ops API/UI will expose bounded current-state audit fields such as active alert status, notification count, and last notification time.
  - This answers the operational question without building a separate history feature.
- Decision: workers without an active routed alert will show no notification audit state.
  - That avoids implying alert delivery where none exists.

## Risks / Trade-offs
- Extra lookup work could make worker listing more expensive.
  - Mitigation: keep the lookup bounded to routed alert keys already derived for active worker alerts.
- Alert state may disappear once resolved.
  - Mitigation: scope this change to current audit visibility, not long-term history.

## Migration Plan
1. Add a helper that resolves current routed alert audit state from the standard alert model.
2. Expose that audit state in the worker management API.
3. Render the audit context in the `web-ng` worker ops surface.
4. Verify active and inactive worker-alert cases.
