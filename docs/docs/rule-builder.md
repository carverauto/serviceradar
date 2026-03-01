---
title: Rule Builder
---

# Rule Builder

ServiceRadar exposes a unified rule builder UI so operators can manage log
normalization (Zen) and response rules without editing raw JSON.

## Where to Find It

Navigate to **Settings → Events** in the web UI.

## Log Normalization (Zen)

Zen rules run first. They normalize incoming syslog, SNMP traps, OTEL logs, and
internal logs before anything is written to CNPG.

In the UI you can:

- Choose a subject (`logs.syslog`, `logs.snmp`, `logs.otel`, or `logs.internal.*`)
- Pick a built-in template (passthrough, strip full_message, CEF severity, SNMP severity)
- Set an order and enable/disable the rule

### Templates

Templates are account-scoped presets. Each account starts with default templates
and can edit or add new ones. Use templates to prefill new rules, then tweak
the specifics before saving.

### Distribution Behavior

Rules are managed in the control plane and distributed automatically to the
components that need them (for example the zen consumer pipeline).

In normal operation, you should not need to manipulate NATS keys or internal
storage directly. Use the UI and confirm effects by watching consumer lag and
pipeline output (see [Tools Pod](./tools.md)).

## Response Rules

Response rules run after normalization and are split into two layers:

1. **Log Promotion Rules**: turn matching logs into OCSF events.
2. **Stateful Alert Rules**: turn repeated signals into alerts.

Use the same UI section to define simple match criteria (subject prefix, service
name, severity, message substring) and threshold windows.

### Templates

Promotion and stateful alert templates work the same way as Zen templates.
Pick a template to prefill a rule, then adjust fields as needed.

## Tips

- Keep rules narrow: prefer specific subject prefixes and severity windows.
- Use short windows for bursty error patterns, longer windows for drift.
- Leave rules disabled while drafting, then enable once validation passes.
