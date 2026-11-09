# Edge spool recovery implementation

Read [design.md](design.md), approved on 2026-11-09, then the authoritative
[tasks.md](tasks.md) and both delta specs. Task checkboxes record complete
contracts, not the existence of a helper or an old moved-task checkmark.

## Current pickup

Implement the prerequisite contracts, then the coordinator and end-to-end
recovery path. Visibility PR #6447 merged as `d54cbc508a76ba99b673015d3006ce928393877f`
with all 20 CI checks passing. Its gate records the user-approved remote-test
exception; live-product validation was not performed.

The current pickup is the production recovery coordinator. Bounded producer
lanes, typed append seals, immutable registration, historical mapping, exact-copy
grants, gateway control validation, consumer effects, paired storage coverage and
same-reservation cleanup are integrated. The protocol remains disabled until the
coordinator and its negotiated runtime path are complete.

Remaining work, in dependency order:

1. Complete interrupted-copy repair under the original reserve. Source-bound
   creation intent and independent finite lane senders are integrated.
2. Wire bounded coordinator discovery, per-authority publication attempts,
   current-trust completion validation and restart cleanup.
3. Complete gateway coverage freshness through publisher handoff and remove
   age expiry from the bounded recovery work queue.
4. Prove the crash matrix and near-full progress with more than 2,048 synthetic
   records across bounded generations; run guarded database persistence tests.
5. Reconcile every task and design decision, run whole-repo tests and standalone
   Go vet, consolidate the choices ledger, then land through no-mistakes/Grok.

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
  completion proof; the coordinator and full-floor proof remain on the critical path.
- Assignment/grant current-state rows are not historical recovery mappings;
  scheduler deletion and mutable epochs must not remove their authority evidence.
- All four coarsening vectors start from journaled per-sequence evidence. Coverage
  must include markerless allocated slots and compare complete classification bodies.
- Source deletion and journal garbage collection have different durability gates.
- All fixtures are synthetic. Tests run with Bazel `--config=remote`; no local builds,
  weakened checks, direct staging pushes, or Helm-only configuration.

Update this pickup and the choices ledger after each verified commit checkpoint.

## Verification

See [verification.md](verification.md) for checkpoint runs and deliberate failing
controls. Database tests loaded by unit shards are not persistence evidence.
