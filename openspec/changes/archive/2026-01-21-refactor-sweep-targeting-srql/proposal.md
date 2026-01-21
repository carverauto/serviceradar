# Change: Refactor sweep targeting to SRQL source of truth

## Why
SweepGroup targeting currently persists a bespoke `target_criteria` DSL, while other targeting systems (sysmon, SNMP) store SRQL directly. This creates parallel targeting paths, UI inconsistencies, and confusion about which query actually drives compiled targets. We want SRQL to be the single source of truth for all targeting so compiled configs always reflect the saved SRQL.

## What Changes
- Add a persisted SRQL field (e.g., `target_query`) to SweepGroup and treat it as the authoritative targeting definition.
- Update sweep compilation to use `target_query` SRQL directly for target resolution and preview counts.
- Update the Network Sweeps UI to use the SRQL input + builder pattern from Sysmon (editable SRQL with optional builder sync), and remove the rules-as-source-of-truth workflow.
- Remove `target_criteria` usage in SweepGroup.
- Treat empty `target_query` as "no dynamic targets" (static targets only).

## Impact
- **Specs**: `sweep-jobs`, `srql`.
- **Code**: SweepGroup resource + migrations, sweep compiler, SRQL query helpers, web-ng sweep group UI, tests, and any data migration utilities.
- **Operational**: No backfill required (scope limited to sweep groups).

## Notes
- There is an active change `fix-sweep-targeting-rules` that addresses UI persistence issues in the current DSL-based workflow. This change will supersede that approach once SRQL becomes the source of truth.
