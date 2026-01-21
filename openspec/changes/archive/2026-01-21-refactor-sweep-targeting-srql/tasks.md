## 1. Planning & Data Model
- [x] 1.1 Confirm SRQL validation strategy (parser/service) for SweepGroup `target_query`.
- [x] 1.2 Add `target_query` attribute to SweepGroup (Ash resource + migration) and remove `target_criteria` from the resource.

## 2. Migration
- [x] 2.1 No backfill required (scope limited to sweep groups; empty target_query == no dynamic targets).

## 3. Compiler & Target Resolution
- [x] 3.1 Update SweepCompiler to use SRQL `target_query` for device IP resolution.
- [x] 3.2 Ensure `static_targets` are merged with SRQL-derived targets.
- [x] 3.3 Remove/retire `target_criteria` usage in compiler.

## 4. Web UI (Network Sweeps)
- [x] 4.1 Replace rules-as-source-of-truth with SRQL input + builder pattern from Sysmon.
- [x] 4.2 Add SRQL validation feedback and device count hint driven by SRQL.
- [x] 4.3 Remove criteria rules persistence and update sweep group form bindings to `target_query`.

## 5. Tests & Cleanup
- [x] 5.1 Update sweep targeting tests to use `target_query` and SRQL-based targeting.
- [x] 5.2 Remove or refactor `target_criteria` tests and helper modules as needed.
- [x] 5.3 Update docs/notes in `openspec/specs/sweep-jobs` and `openspec/specs/srql`.
