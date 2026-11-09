# Edge spool recovery implementation

Read [design.md](design.md), approved on 2026-11-09, then the authoritative
[tasks.md](tasks.md) and both delta specs. Task checkboxes record complete
contracts, not the existence of a helper or an old moved-task checkmark.

## Current pickup

Implement the prerequisite contracts, then the coordinator and end-to-end
recovery path. Visibility PR #6447 merged as `d54cbc508a76ba99b673015d3006ce928393877f`
with all 20 CI checks passing. Its gate records the user-approved remote-test
exception; live-product validation was not performed.

Lane generation options and the production filesystem probe are integrated.
The recovery registration protocol and allocation partition validator are verified.
Durable operation storage, gateway handlers and runtime negotiation are next; declaring the protocol does not enable the coordinator. Typed mapping values, attribution constructors and redundant frozen journals are
integrated. Durable mapping issuance and attribution sidecars are proceeding
independently; operation storage is compiled, with database tests still pending.

## Dependency order

| Pass | Contract | Depends on |
| --- | --- | --- |
| A | Shared lane options and physical reserve protection | Existing spool and allocator |
| B | Tagged assignment values, immutable mapping and issuance ordering | Frozen span key |
| C | Validated attribution result and cross-language local-binding grammar | Existing composed validators |
| D | Durable sidecars, lane routing/migration, closed-generation senders | A, B, C |
| E | Recovery registration/authorization/query and durable consumer state | B, authenticated session and existing capability grammar |
| F | Two-copy coordinator journal, bounded pages, relocation and coverage reclaim | D, E |
| G | Consumer repair transaction, signed completion, gateway prefix integration | B, E, F |
| H | Negotiated runtime activation, crash matrix, full validation and landing | All preceding passes |

Independent passes use isolated worktrees; shared API changes are integrated
before dependent implementations. The Go gateway-prefix package is a comparison
oracle. The live gateway prefix owner is Elixir `ServiceRadar.Edge.ResolvedPrefix`.

## Evidence and constraints

- Companion classification-spans ABI and canonical recovery hashes are present.
- The rescue commit was absent from 135 local repository object stores; rebuild
  from the frozen contract instead of repeating the search.
- LaneSet now accepts generation-specific existing spool options, and production
  reserve checks probe the actual spool filesystem. Agent runtime lane migration
  and binding persistence remain open.
- Assignment/grant current-state rows are not historical recovery mappings;
  scheduler deletion and mutable epochs must not remove their authority evidence.
- All four coarsening vectors start from journaled per-sequence evidence. Coverage
  must include markerless allocated slots and compare complete classification bodies.
- Source deletion and journal garbage collection have different durability gates.
- All fixtures are synthetic. Tests run with Bazel `--config=remote`; no local builds,
  weakened checks, direct staging pushes, or Helm-only configuration.

Update this pickup and the choices ledger after each verified commit checkpoint.

## Verification ledger

- Lane option regressions failed against the old opener in BuildBuddy
  `3e21d25e-426c-4e7a-a9b4-c3a9f0d9fa73`; the missing production filesystem probe
  failed in `056ff478-7dc5-4e52-986c-76c3ee29a10a`. Fixed spool/agent targets passed
  in `4a827ec1-317b-4cd2-9c31-fb35e3a6d265`.
- Integrated Go edge/agent plus Elixir edge contracts passed all 14 targets in
  `c23bdaf2-453c-4e5d-b15d-1aa6491bfadd`. Removing the registration partition guard
  made both markerless-slot omission and copy/loss-overlap tests fail in
  `3944d010-0c04-4e1f-8b0f-b30f8fce06bc`; the guard was restored afterward. The restored Elixir edge shard and all proto
  targets passed seven tests in `51652717-faaf-428d-98ef-2d17e6bcf9f7`.

- Binding constructors/grammar passed Go, Elixir edge and core quality in
  `85826a99-d281-4615-be10-c8b7b52bc42a`; 1,116 Elixir tests passed. Journal
  adjacency and complete-body mutations failed in `ac0a60bc` and `6d1794a6`;
  restored journal tests passed `0f260fae-8f12-4e7c-b013-d0194c62176e`. The clean
  journal ownership move passed spool in `d28e4687-c8b5-4a69-8bdc-04a94a236629`.
- Operation storage schema generated remotely through its committed writeback
  target. Database replay/conflict tests are pending guarded integration execution;
  unit-shard loading is not database evidence.
- Integrated Go edge/agent, Elixir edge and core quality passed all 15 targets in
  `9782af13-4dd7-475d-9364-b832fbcf3690`. Operation storage database tests were
  loaded but excluded by that unit shard; their persistence assertions remain pending.
