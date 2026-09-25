# Tasks

## 1. Decision log

- [x] 1.1 Add `IdentityDecision` (resource, migration in `platform`, viewer read, system write,
      upsert per decision key counting repeats).
- [x] 1.2 Add `Identity.DecisionLog` (best-effort bulk write; a failed write is logged and
      counted in telemetry).
- [x] 1.3 Record MergePolicy refusals, MergeEngine guard refusals, source-authority blocks,
      alias invalidations and active-IP conflicts.
- [x] 1.4 Integration tests for each decision path, including the repeat-counting upsert.

## 2. Formal model

- [x] 2.1 Read each trace step's `recorded` decisions from `identity_decisions` rows.
- [x] 2.2 Remove `silent_blocks` from `DireResolution.tla`, its witness and target, the trace
      configurations and `@current_bugs`; `NoSilentDecision` stays in every
      `resolution_goal_*` configuration.
