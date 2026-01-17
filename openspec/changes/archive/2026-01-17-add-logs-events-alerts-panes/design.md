## Context
- Logs (syslog, SNMP traps, GELF, OTEL logs) represent raw, append-only signals.
- Events represent derived conditions in OCSF form (including internal health state messages).
- Alerts already exist as stateful records with escalation and notification logic.
- The UI currently lacks a unified, discoverable workflow across logs, events, and alerts.

## Goals / Non-Goals
- Goals:
  - Clarify the semantics of logs, events, and alerts across the platform.
  - Preserve raw logs while enabling rule-based promotion to events.
  - Keep alerts stateful and linked to originating events.
  - Provide three separate UI panes with linking between related records.
- Non-Goals:
  - Replacing the alert lifecycle state machine.
  - Building a full rule editor UI in the first iteration.
  - Rewriting existing ingestion systems wholesale.

## Decisions
- Logs remain raw and append-only; SNMP traps stay in the logs pipeline even when promoted.
- Events are derived and stored only in OCSF format with explicit references to source logs and rules.
- Alerts are generated from events and must reference the triggering event for auditability.
- Rule evaluation is tenant-scoped and should reuse existing rule definitions where possible.

## Risks / Trade-offs
- Rule promotion adds latency and complexity; guardrails are needed to avoid log loss or duplicate events.
- Maintaining both raw logs and derived events increases storage usage but preserves audit trails.
- Integrating with legacy rule engines (e.g., serviceradar-zen) may require adapters.

## Migration Plan
- Document current sources (syslog, SNMP traps, GELF, OTEL logs, internal health events) and classify them.
- Roll out promotion rules per tenant without backfilling historical logs to events.
- Ensure alerts continue to function during the transition by linking to new events when available.

## Open Questions
- Should serviceradar-zen remain a standalone rule engine or be embedded via Rustler?
- Which log schema/entity will be canonical for promotion (existing logs entity or a new table)?
- What minimum metadata is required in logs to support reliable promotion and correlation?
