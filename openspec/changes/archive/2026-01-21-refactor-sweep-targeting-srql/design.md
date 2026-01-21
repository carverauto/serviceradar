## Context
SweepGroup targeting currently uses a custom `target_criteria` map and a rules-based UI. Other configuration surfaces (Sysmon, SNMP profiles) already store SRQL as `target_query` and treat SRQL as the source of truth. This split creates drift between UI previews and compiled targets, and requires special logic in SweepCompiler.

## Goals / Non-Goals
- Goals:
  - Store SRQL directly on SweepGroup and use it as the authoritative targeting definition.
  - Ensure sweep compilation and preview counts are derived from the same SRQL query.
  - Reuse the Sysmon SRQL input + builder UI pattern in Network Sweeps.
  - Keep scope limited to sweep groups (no backfill required).
- Non-Goals:
  - Redesign SRQL grammar or introduce new SRQL keywords.
  - Remove static targets (IPs/CIDRs) — they remain as explicit overrides merged with SRQL results.
  - Change Sysmon/SNMP targeting (already SRQL-based).

## Decisions
- **Authoritative field**: add `target_query` to SweepGroup and use it as the only source of truth for dynamic targets.
- **Migration**: remove `target_criteria` and do not backfill.
- **Validation**: only persist valid SRQL; invalid queries are rejected with a clear validation error.
- **Compilation**: SweepCompiler uses SRQL to resolve device IPs and merges results with `static_targets`.
- **UI**: Network Sweeps uses the same SRQL input/builder UX as Sysmon (editable SRQL with builder sync + device count hint). The rules builder is removed or demoted to a read-only representation.
- **Empty query**: blank `target_query` means no dynamic targets (static targets only).

## Risks / Trade-offs
- **Behavior change**: SRQL parsing/validation could reject previously accepted inputs. Mitigation: validate in the UI and surface errors clearly.
- **User confusion**: Removing the rules-only UX might affect existing workflows. Mitigation: provide SRQL examples and keep the builder for common cases.

## Migration Plan
1. Add `target_query` attribute + migration to SweepGroup.
2. Update SweepCompiler to use SRQL for targeting and merge static targets.
3. Update UI + tests to use SRQL input/builder pattern.
4. Remove `target_criteria` from the resource and compiler.

## Open Questions
- None.
