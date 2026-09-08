# Change: update-event-alert-dedup-and-suppression

## Why

Critical Falco events currently flow through `AlertGenerator.from_event/2` as one-off alert creations. When the same security condition fires repeatedly in a short burst, the platform creates multiple alert rows and repeatedly attempts outbound notification delivery for what operators experience as one incident.

`WebhookNotifier` cooldown only throttles outbound webhook delivery in process memory. It does not prevent duplicate alert creation, and when the notifier is unavailable it still produces repeated warning logs for the same incident burst. Operators need incident-based suppression semantics and UI-visible knobs for grouping, cooldown, and renotify behavior.

## What Changes

- Introduce incident deduplication for event-derived alerts so repeated matching events update one active incident instead of creating a new alert row each time.
- Define configurable grouping and suppression behavior for event-derived alerts, with Falco/security detections as the first concrete use case.
- Suppress repeated immediate notification attempts for duplicate events while an incident remains active and inside its cooldown window.
- Expose incident grouping and notification suppression knobs in the rules UI so operators can tune grouping keys, cooldown, and renotify behavior.
- Preserve provenance by keeping raw logs and OCSF events intact while recording duplicate occurrence counts and recent activity on the alert incident.

## Impact

- Affected specs: `observability-signals`, `observability-rule-management`
- Affected code: `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/falco_events.ex`, `elixir/serviceradar_core/lib/serviceradar/monitoring/alert_generator.ex`, `elixir/serviceradar_core/lib/serviceradar/monitoring/alert.ex`, observability rule resources/templates, and `elixir/web-ng` rules/alert UI surfaces
- Related work: this change narrows the alerting behavior introduced by `add-falco-ocsf-event-consumer` so Falco-promoted events behave like incidents instead of one-alert-per-event bursts
