# Edge spool recovery implementation

Read [design.md](design.md), approved on 2026-11-09, then the authoritative
[tasks.md](tasks.md) and both delta specs. Task checkboxes record complete
contracts, not the existence of a helper or an old moved-task checkmark.

## Current pickup

The implementation is complete and entering its final validation gate.
Visibility PR #6447 merged as `d54cbc508a76ba99b673015d3006ce928393877f`
with all 20 CI checks passing. Its gate records the user-approved remote-test
exception; live-product validation was not performed.

The bounded production coordinator is integrated. It inventories retained recovery
storage before admission and delivery, cancels and joins each source session
before freeze, journals immutable transport attempts, requires exact copy grants,
and validates signed consumer completion before cleanup. Actual sender tests
cover interrupted receipt writes, restart accounting and delivery of a new record
after recovery. The integrated Go and process-harness selfchecks passed all 16
targets; standalone Go vet also passed. The final activated tree passed all 523
runnable unit targets, with two Swift platform skips.

Remaining work, in dependency order:

1. Reconcile task completion with the remaining database-backed CI evidence. Core must deploy before
   gateway/agent; downstream availability remains a retryable RPC condition,
   not a feature-version toggle.
   Require `BazelCI Core Integration` to execute the boxed database contracts and
   the process vertical slice; unit loading is not database execution.
2. Land through no-mistakes with reviewer Grok, verify exact-head CI, and record
   the PR and merge commit. The active gate publishes PR #6469; guarded database
   contracts and the vertical slice must still pass `BazelCI Core Integration`
   on its final published head.

Pre-evidence sweep leases persisted before core recorded issuance evidence are
never resumed into bounded storage and stay on disk unchanged. Each new control
session receives a fresh full lease from core; see the admission boundary in
[design.md](design.md#admission-boundary-for-pre-evidence-lease-authority).

The storage near-full proof covers 2,049 synthetic records across nine damaged
generations. It is separate from the composed driver tests; no near-full live
product deployment validation is claimed. Decisions are consolidated in
[choices.md](choices.md), and run evidence is in [verification.md](verification.md).

The owner excluded legacy compatibility on 2026-11-09. Preserve and account old
flat files as unsupported retained storage; do not implement migration, legacy
draining or a copy-only recovery protocol. See [legacy-recovery-decision.md](legacy-recovery-decision.md).

## Dependency order

| Pass | Contract | Depends on |
| --- | --- | --- |
| A | Shared lane options and physical reserve protection | Existing spool and allocator |
| B | Tagged assignment values, immutable mapping and issuance ordering | Frozen span key |
| C | Validated attribution result and cross-language local-binding grammar | Existing composed validators |
| D | Durable sidecars, lane routing, closed-generation senders | A, B, C |
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
- Production lanes and reserve checks use the shared allocator. Integrated cleanup
  preserves rejection/control archives and releases capacity only after its durable
  completion proof. Composed driver and storage full-floor tests passed; guarded
  consumer database execution remains required.
- Assignment/grant current-state rows are not historical recovery mappings;
  scheduler deletion and mutable epochs must not remove their authority evidence.
- All four coarsening vectors start from journaled per-sequence evidence. Coverage
  must include markerless allocated slots and compare complete classification bodies.
- Source deletion and journal garbage collection have different durability gates.
- All fixtures are synthetic. Bazel tests run with `--config=remote`; standalone
  Go vet is also required. No weakened checks, direct staging pushes, or Helm-only
  configuration.

Update this pickup and the choices ledger after each verified commit checkpoint.

## Verification

See [verification.md](verification.md) for checkpoint runs and deliberate failing
controls. Database tests loaded by unit shards are not persistence evidence.
