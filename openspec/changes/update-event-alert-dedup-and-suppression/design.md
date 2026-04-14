## Context

The current event-derived alert path is immediate:

1. Falco events are persisted into `logs`
2. higher-severity Falco events are promoted into `ocsf_events`
3. critical/fatal Falco events call `AlertGenerator.from_event/2`
4. `AlertGenerator` creates a new `platform.alerts` row and then calls `WebhookNotifier.send_alert/1`

This path has two mismatches with operator expectations:

- repeated detections for the same ongoing condition create multiple alert incidents
- notifier cooldown runs after alert creation and only applies to outbound webhook delivery

The system already has stateful alert concepts such as `group_by`, `cooldown_seconds`, and `renotify_seconds`, but the direct event-to-alert path does not reuse those incident semantics.

## Goals

- Collapse repeated event bursts into one active alert incident
- Make grouping and suppression behavior operator-configurable
- Preserve raw log and OCSF event fidelity
- Avoid repeated immediate notification attempts for duplicate events inside the incident cooldown

## Non-Goals

- Dropping or deduplicating raw Falco logs or OCSF events
- Replacing the existing alert resource/state machine
- Designing a new notification transport or routing subsystem
- Introducing multitenant override modes outside the existing deployment-scoped model

## Decisions

- Decision: event-derived alerts will use an incident fingerprint instead of unconditional one-alert-per-event creation.
  The fingerprint should be derived from the alert source plus configured grouping fields so repeated events map to one active incident.

- Decision: duplicate events inside an active incident window will update the incident instead of creating a new alert row.
  Incident updates should record at least occurrence count, first seen, last seen, and enough grouping metadata for audit/debugging.

- Decision: notification cadence will follow incident semantics, not raw event count.
  The initial incident creation may attempt notification immediately. Duplicate events inside cooldown must not trigger another immediate attempt. Renotify remains the mechanism for sustained incidents.

- Decision: rules UI controls will reuse existing observability concepts where possible.
  `group_by`, `cooldown_seconds`, and `renotify_seconds` are the right user-facing primitives. Falco/security defaults should be expressible through those knobs instead of a hard-coded special case with no UI.

- Decision: Falco will be the first direct event source migrated to incident-based behavior.
  The design should remain generic for other event-derived alert sources that currently or eventually bypass stateful rules.

## Risks / Trade-offs

- Over-grouping can hide distinct incidents.
  Mitigation: make grouping keys explicit and operator-configurable, and surface duplicate counters plus recent activity in the alert UI.

- Under-grouping can preserve the current alert storm behavior.
  Mitigation: ship sensible defaults for Falco/security detections and validate them with representative payloads.

- Moving from per-event alerts to per-incident alerts changes alert volume and operator workflows.
  Mitigation: preserve all event records and make incident update metadata inspectable so no source evidence is lost.

## Migration Plan

1. Define the incident fingerprint contract and default grouping for Falco-derived alerts.
2. Update event-derived alert creation to create-or-update an active incident.
3. Record duplicate occurrence metadata and suppress repeated immediate notification attempts inside cooldown.
4. Expose grouping/cooldown/renotify controls in the rules UI.
5. Backfill default values for existing event-derived alert policies so behavior remains deterministic after rollout.

## Open Questions

- Should Falco direct auto-alerting become an editable seeded response rule, or should it remain an internal path that consumes the same persisted policy shape?
- How much recent-event provenance should be stored on the incident itself versus separate history records?
