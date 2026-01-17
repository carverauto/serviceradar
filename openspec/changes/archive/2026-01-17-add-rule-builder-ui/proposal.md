# Change: Unified Rule Builder UI for Log Normalization and Response Rules

## Why
Operators cannot manage Zen rules or stateful alert rules without editing JSON and pushing to KV manually. This blocks adoption and makes tenant-specific rule management brittle. We need a single, simple UI that persists rule definitions per tenant in CNPG, syncs Zen rules to KV via datasvc, manages stateful response rules without exposing raw JSON, and lets tenants author and edit reusable templates.

## What Changes
- Add tenant-scoped storage for Zen rule definitions in CNPG (Ash resources) and compile them into GoRules JSON Decision Models (JDM) for KV sync.
- Add a unified Rule Builder UI in web-ng (Settings) for:
  - Log normalization rules (Zen) targeting syslog, SNMP traps, OTEL logs, and internal logs.
  - Response rules (stateful alert engine) for threshold-based alerts.
- Add tenant-scoped template libraries for Zen rules and response rules (promotion + stateful), seeded with default templates that tenants can edit or extend.
- Add template editors that reuse the existing rule builder UI so users can create and update templates without raw JSON.
- Consolidate settings navigation with a shared Settings layout and add a dedicated entry for the Rule Builder UI.
- Add core-elx APIs/services to validate, persist, and sync rules via datasvc KV (push updates and reconcile on startup).
- Seed default Zen rules into each tenant schema during onboarding (including the platform tenant) so KV no longer requires manual bootstrap.
- Ensure every supported subject has a default passthrough rule/template labeled as the baseline option.
- Update docs to replace manual KV instructions with UI-driven workflows and include rule semantics/examples.

## Impact
- Affected specs: new `observability-rule-management` capability (plus potential follow-up updates to existing observability specs).
- Affected code: core-elx (Ash resources + datasvc KV sync), web-ng (LiveView UI), docs (syslog/snmp + new rule builder guide).
