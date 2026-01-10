# Change: Unified Rule Builder UI for Log Normalization and Response Rules

## Why
Operators cannot manage Zen rules or stateful alert rules without editing JSON and pushing to KV manually. This blocks adoption and makes tenant-specific rule management brittle. We need a single, simple UI that persists rule definitions per tenant in CNPG, syncs Zen rules to KV via datasvc, and manages stateful response rules without exposing raw JSON.

## What Changes
- Add tenant-scoped storage for Zen rule definitions in CNPG (Ash resources) and compile them into GoRules JSON Decision Models (JDM) for KV sync.
- Add a unified Rule Builder UI in web-ng (Settings) for:
  - Log normalization rules (Zen) targeting syslog, SNMP traps, OTEL logs, and internal logs.
  - Response rules (stateful alert engine) for threshold-based alerts.
- Add core-elx APIs/services to validate, persist, and sync rules via datasvc KV (push updates and reconcile on startup).
- Update docs to replace manual KV instructions with UI-driven workflows and include rule semantics/examples.

## Impact
- Affected specs: new `observability-rule-management` capability (plus potential follow-up updates to existing observability specs).
- Affected code: core-elx (Ash resources + datasvc KV sync), web-ng (LiveView UI), docs (syslog/snmp + new rule builder guide).
