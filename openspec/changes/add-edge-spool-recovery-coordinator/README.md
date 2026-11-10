# Edge spool recovery implementation

Read [design.md](design.md), approved on 2026-11-09, then the authoritative
[tasks.md](tasks.md) and both delta specs. Task checkboxes record complete
contracts, not the existence of a helper or an old moved-task checkmark.

## Implementation and deployment status

Bounded recovery merged in [PR #6469](https://github.com/carverauto/serviceradar/pull/6469)
as `161843f1ca2a4017437f36041674354db9491cd0` on 2026-11-10 at 08:17:16 UTC.
All 21 reported checks passed for published head
`7c46cbc8a7bb16a2fa647838355f26acf86a5141`. The guarded database contracts and
real process vertical executed; [verification.md](verification.md) records each
workflow's tested merge, results and limitations. Tasks 1.1-1.10 and 2.1 are complete.
Visibility [PR #6447](https://github.com/carverauto/serviceradar/pull/6447) previously
merged as `d54cbc508a76ba99b673015d3006ce928393877f`.

Deployment has not been authorized or verified. Deploy capable core before gateway
and agent when authorized. Keep this change active until deployment is recorded;
OpenSpec Stage 3 then requires a separate archive PR. Merge and CI success alone
do not establish deployment.

The owner approved automatic recovery only for new bounded attributed generations.
Existing unsupported flat or oversized storage remains intact, charged and reported.
No legacy drain, migration, copy-only recovery or invented historical identity is
in scope. Pre-evidence persisted sweep leases are not resumed into bounded storage
and stay on disk unchanged. Each new control session requests a fresh full lease
for its own agent's existing active assignments, retrying with bounded backoff.
Delivery serializes with the lease pass under the cluster-wide per-lease lock;
planning decisions use short transactions that lock and re-read the group row.
Both lease-delivery and lease-pass database contracts executed in the final gate.
See the [admission boundary](design.md#admission-boundary-for-pre-evidence-lease-authority).

The near-full storage proof uses 2,049 synthetic records across nine damaged
generations. Synthetic storage and composed coordinator tests establish crash
recovery separately from the real process vertical, which passed A-H without
damaged-spool injection. No near-full live-product validation is claimed.
See [choices.md](choices.md) and [legacy-recovery-decision.md](legacy-recovery-decision.md).

## Implementation dependency record

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

Independent passes used isolated worktrees; shared API changes were integrated
before dependent implementations. The Go gateway-prefix package is a comparison
oracle. The live gateway prefix owner is Elixir `ServiceRadar.Edge.ResolvedPrefix`.

## Evidence and constraints

- Companion classification-spans ABI and canonical recovery hashes are present.
- The rescue commit was absent from 135 local repository object stores; rebuild
  from the frozen contract instead of repeating the search.
- Production lanes and reserve checks use the shared allocator. Integrated cleanup
  preserves rejection/control archives and releases capacity only after its durable
  completion proof. Composed driver, storage full-floor and guarded
  consumer database checks passed; their distinct evidence is in verification.md.
- Assignment/grant current-state rows are not historical recovery mappings;
  scheduler deletion and mutable epochs must not remove their authority evidence.
- All four coarsening vectors start from journaled per-sequence evidence. Coverage
  must include markerless allocated slots and compare complete classification bodies.
- Source deletion and journal garbage collection have different durability gates.
- All fixtures are synthetic. Bazel tests run with `--config=remote`; standalone
  Go vet is also required. No weakened checks, direct staging pushes, or Helm-only
  configuration.

## Verification

See [verification.md](verification.md) for checkpoint runs and deliberate failing
controls. Database tests loaded by unit shards are not persistence evidence.
