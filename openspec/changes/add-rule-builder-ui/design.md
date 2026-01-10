## Context
Zen rules are currently JSON-only and written via KV tooling; stateful alert rules exist in CNPG but have no UI. Operators need a single interface that hides engine differences while keeping rules tenant-scoped and auditable.

## Goals / Non-Goals
- Goals:
  - Unified UI for log normalization and response rules (no raw JSON).
  - Clean, consistent Settings navigation that makes rules easy to discover.
  - Tenant-scoped persistence and KV synchronization for Zen rules.
  - Simple rule templates for syslog, SNMP traps, OTEL logs, and internal logs.
  - Keep Zen and stateful engines operationally separate but user-facing unified.
- Non-Goals:
  - Full GoRules graph editor or arbitrary JDM imports.
  - Cross-tenant rule sharing or bypassing Ash multi-tenancy.

## Decisions
- **Rule naming in UI**: Use a single section titled "Event Notifications & Response Rules" with two tabs:
  - "Log Normalization" (Zen)
  - "Response Rules" (Stateful alerts)
- **Settings layout**: Introduce a shared Settings layout with a left navigation and route all settings pages under
  `/settings/*`, keeping a compatibility redirect for `/users/settings`.
- **Storage model**: Add a new Ash resource (tenant-scoped) for Zen rules that stores both:
  - A structured builder config (for UI editing)
  - The compiled JDM JSON (for KV sync)
- **Sync pipeline**: On create/update/delete, core-elx writes the compiled JDM to datasvc KV under
  `agents/<agent-id>/<stream>/<subject>/<rule>.json`, and stores the KV revision on the rule record.
  A reconciliation job re-publishes all active rules on startup.
- **Subject model**: Zen rules target a finite subject set: `logs.syslog`, `logs.snmp`,
  `logs.otel`, and `logs.internal.*`. The UI constrains these choices to reduce errors.
- **Promotion flow**: Log promotion rules (existing `LogPromotionRule`) and stateful alert rules
  remain in CNPG and are managed via the same UI section, but stored in separate resources.

## Risks / Trade-offs
- Constraining the builder to a subset of JDM features reduces power but improves usability.
- Compiled JDM must be deterministic and validated to avoid inconsistent rule behavior.

## Migration Plan
- Add new tables and Ash resources for Zen rules.
- Seed existing JSON rules into the new table (optional script or one-time import).
- Update docs to reference the UI and deprecate manual KV steps.

## Open Questions
- Do we expose a "raw JSON" advanced view behind a feature flag for power users?
- Should rule templates be versioned with explicit compatibility markers?
- Should `/users/settings` remain as an alias long-term or be deprecated after the new Settings layout lands?
