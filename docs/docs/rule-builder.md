---
title: Rule Builder
---

# Rule Builder

ServiceRadar exposes a unified rule builder UI so operators can manage log
normalization (Zen) and response rules without editing raw JSON.

## Where to Find It

Navigate to **Settings → Rules** (`/settings/rules`) in the web UI. The page title
is **Events**, with tabs for log normalization (Zen), event promotion, and alerts.

## Log Normalization (Zen)

Zen rules run first in the core-elx ingestion path. They normalize incoming
syslog, SNMP traps, and OTEL logs before anything is written to CNPG.

The bundled core-elx rule set has decision groups for these subjects:

- `logs.syslog` - passthrough, strip full_message, CEF severity
- `logs.snmp` - passthrough, SNMP severity
- `logs.otel` - passthrough
- `otel.metrics.raw` - passthrough (raw OTEL metrics)

In the UI you can:

- Choose a subject (`logs.syslog`, `logs.snmp`, or `logs.otel`)
- Pick a built-in template (passthrough, strip full_message, CEF severity, SNMP severity)
- Set an order and enable/disable the rule

### Templates

Templates are account-scoped presets. Each account starts with default templates
and can edit or add new ones. Use templates to prefill new rules, then tweak
the specifics before saving.

### Distribution Behavior

Rules are managed in the control plane and distributed automatically to the
components that need them, including the core-elx ingestion pipeline.

In normal operation, you should not need to manipulate NATS keys or internal
storage directly. Use the UI and confirm effects by watching consumer lag and
pipeline output (see [Tools Pod](./tools.md)).

## Response Rules

Response rules run after normalization and are split into two layers:

1. **Log Promotion Rules**: turn matching logs into OCSF events.
2. **Stateful Alert Rules**: turn repeated signals into alerts.

Use the same UI section to define simple match criteria (subject prefix, service
name, severity, message substring) and threshold windows.

In **Settings → Rules → Alerts** (`/settings/rules?tab=alerts`), operators can also
edit incident controls on stateful alert rules:

- `group_by` decides which fields keep events inside one incident.
- `cooldown_seconds` prevents repeated immediate notifications for duplicate bursts.
- `renotify_seconds` controls reminder cadence for long-lived incidents.

Alerts do not page by themselves. After a rule fires, a notification **route**
must match it and send it to a **channel**. See the
[Notifications Quickstart](./notification-quickstart.md).

The default Falco rule ships with `group_by = ["rule", "hostname"]`, so repeated
critical detections from the same rule on the same host stay within one active
incident unless the cooldown gap is exceeded.

### Templates

Promotion and stateful alert templates work the same way as Zen templates.
Pick a template to prefill a rule, then adjust fields as needed.

## Tips

- Keep rules narrow: prefer specific subject prefixes and severity windows.
- Use short windows for bursty error patterns, longer windows for drift.
- Leave rules disabled while drafting, then enable once validation passes.
