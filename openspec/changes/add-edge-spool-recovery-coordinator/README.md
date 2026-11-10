# Edge spool recovery implementation

Read [design.md](design.md), approved on 2026-11-09, then the authoritative
[tasks.md](tasks.md) and both delta specs. Task checkboxes record complete
contracts, not the existence of a helper or an old moved-task checkmark.

## Current pickup

Bounded recovery is implemented in PR [#6469](https://github.com/carverauto/serviceradar/pull/6469).
The final validation and landing gate is still open. Visibility PR
[#6447](https://github.com/carverauto/serviceradar/pull/6447) merged as
`d54cbc508a76ba99b673015d3006ce928393877f`; its approved remote-test exception
does not waive this change's database or process-integration contracts.

The newest completed checkpoint is a full `make test` at
`87b5a849e1aef445ff9749f6c9d9b6ddab72b9b5`: 525 targets passed with two Swift
platform skips (BuildBuddy invocation `87ec63b1-b4b4-48b5-9f87-124a97c91767`).
It predates the lease-delivery lock and the narrowed refresh, so it is not
final-head evidence. Require `BazelCI Core Integration` to execute the guarded
database contracts and the real process vertical on the final published head.
Unit loading and harness selfchecks do not satisfy those checks.

After the final gate passes, reconcile the task checklist with its actual test
results, land PR #6469, and record the merge commit. Deploy capable core before
gateway and agent. Record deployment before opening the separate OpenSpec archive
PR; merge alone does not authorize archiving.

The owner approved automatic recovery only for new bounded attributed generations.
Existing unsupported flat or oversized storage remains intact, charged and reported.
No legacy drain, migration, copy-only recovery or invented historical identity is
in scope. Pre-evidence persisted sweep leases are not resumed into bounded storage
and stay on disk unchanged. Each new control session requests a fresh full lease
for its own agent only, retried with bounded backoff until it succeeds or the
session ends; it serializes with the lease pass on a cluster-wide per-lease lock.
Their guarded database coverage (`lease_delivery_db`) must execute in the
integration gate; see the admission boundary in
[design.md](design.md#admission-boundary-for-pre-evidence-lease-authority).

The near-full storage proof uses 2,049 synthetic records across nine damaged
generations. It is separate from composed driver tests and the real process
vertical; it does not establish near-full live-product deployment behavior.
See [choices.md](choices.md), [verification.md](verification.md), and
[legacy-recovery-decision.md](legacy-recovery-decision.md).

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
