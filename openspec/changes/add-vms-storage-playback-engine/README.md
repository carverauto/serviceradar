# VMS implementation handoff

## Current pickup

[Durable recording stop #5989](https://github.com/carverauto/serviceradar/pull/5989)
is merged at `b06d0b6b12e42519aa0bda8157692feedbffd12d`. All 20 checks passed,
including the six new guarded database cases. [Cloud media installation #187](https://github.com/carverauto/serviceradar-control/pull/187)
is merged at `a55f904cd9f929a58e133ca02c9b6dbe58323b73`; all five checks passed,
including its actual Timescale database suite. The Cloud installation proves
media authentication and chart persistence, not storage authority or readiness.

The current checkpoint implements [bounded init-object authority](init-authority.md):
a fresh origin/configuration/workload-bound installation exchange, one durable
dispatch grant, isolated credential custody, conditional PUT and exact-byte
verification. Its 30-second installation window and at-most-five-second grant
are nonrenewable. Old qualification receipts remain diagnostic. Permanent stop,
original operation deadlines and late evidence remain enforced.
The integrated remote suite passed 460 targets with two platform skips.
No-mistakes publication and actual guarded Core/Web database execution remain
the immediate gates; [validation.md](validation.md) distinguishes executed
checks from the eleven pending database cases.

Production recording stays disabled. Preserve the operator-confirmed live RTSP
path and all existing ownership, manifest, archive, intent and dispatch
assertions. No rollout, live provider request, archive availability, recording
activation or local-media reclamation is introduced here. Synthetic provider I/O
belongs to the new checkpoint's executable acceptance, not a live rollout.

## Priority order

1. Finish no-mistakes validation/publication and guarded database execution for
   the implemented init-only authority and exact-byte upload checkpoint.
   Keep broader desired/applied media configuration and continuous admission
   unavailable. Cloud
   [issue #182](https://github.com/carverauto/serviceradar-control/issues/182) and
   [issue #183](https://github.com/carverauto/serviceradar-control/issues/183) also
   own provisioning and preservation before teardown.
2. After the init checkpoint passes, add streaming media,
   multipart reconciliation, recovery-manifest verification and index publication.
3. Complete playback, holds/retention, hosted lifecycle and optional workers in
   [tasks.md](tasks.md), following [Cloud ownership](cloud-control-plane.md).
4. Keep tasks 0.4 and 0.6 open: codec/RTCP/logical-byte experiments do not select
   production support, synchronization tolerances or capacity objectives. Complete
   synthetic security/failure/capacity acceptance before designated live acceptance.

## Evidence ledger

| Contract | Evidence | Remaining gate |
| --- | --- | --- |
| Runtime relay ownership | #5950/#5952/#5954 merged; #5954 head `89d50a7f`, guarded `7cbd7c77` passed all 12 targets | Deployment acceptance |
| Frozen archive and destination | #5955 merged at `88c5a324`; head `72a81f96`, guarded `0df082fa` passed all 12 targets | Provider authority and verified bytes |
| Immutable upload intent | #5960 merged at `29b30748`; guarded `853e4601` passed all 12 targets including five intent cases | Wire operations |
| Durable dispatch observations | #5966 merged; final head `831e8893`, guarded Core `d85a7307` and Web `6aafb922` passed 12 and seven targets uncached, with all lifecycle statuses zero | Current qualification and isolated storage boundary |
| Qualification report | #5973 merged; 18 final checks passed. Six protocol cases; full remote `fc10c612` passes 459 targets after formatting, with two Swift platform skips; see [validation](validation.md) | Authenticated desired/applied contract, evidence verification and current authority enforcement |
| Private qualification receipts | #5979 merged; 19 final checks passed. Core `42cf4965` and Web `8a15b4d4` executed all 12/seven guarded targets uncached; all lifecycle statuses zero, all five new DB cases included | Full desired/applied installation remains open |
| Deployment-scoped media authentication | #5983 merged; final head `66d22624` passed all checks. Core `59ceece3` and Web `f8b9178b` executed all 12/seven guarded targets; lifecycle statuses zero. HTTP shard 0: 819 tests + two properties, zero failures, both receipt cases traced | Full desired/applied authority remains open |
| Durable recording stop | #5989 merged; 20 checks passed. Core `e00f8d32` and Web `2602f4c1` executed 12 and seven guarded targets; all lifecycle statuses zero. Five core cases covered by included owners; HTTP case explicitly traced | Full fleet drain and positive authority remain separate |
| Cloud media installation | #187 merged; all five checks passed; Timescale CI 3230 tests, zero failures, 10 skips, all 17 required cases enabled | Provider provisioning, qualification, isolated workload and lifecycle preservation |
| Init-object authority | Corrected full remote `e901eb3e` passed 460 targets with two platform skips; all three review regressions have negative controls; TLS/runtime/release/Helm owners passed; see [validation](validation.md) | No-mistakes publication and final-head execution of ten Core cases and one Web HTTP/database case |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [qualification-report.md](qualification-report.md),
[qualification-receipts.md](qualification-receipts.md), [media-authentication.md](media-authentication.md),
[recording-control.md](recording-control.md), [init-authority.md](init-authority.md), [upload-intent.md](upload-intent.md),
[upload-dispatch.md](upload-dispatch.md) and
the current diff. Finish no-mistakes validation/publication and actual guarded
Core/Web database execution for the init-only checkpoint before extending archive
transport and full media configuration.
A stopped configuration has no resume variant; do not add one without
fencing in-flight work and enforcing current positive authority. A persisted receipt is
not an applied revision. Media authentication identifies the responding process;
it does not prove fleet-wide credential retirement or provider access. Do not promote old
receipts into authority or treat withdrawal as provider cancellation/revocation.

Preserve the dispatch's original deadline, single marker, late observations and
permanent conflict evidence. Lease replacement must never rearm an unresolved
operation. Timeout/revocation does not prove remote cancellation. Credentials
stay behind an isolated workload boundary; future provider I/O stays outside
CNPG transactions. A destination change cannot retarget a retained block, and
neither an intent nor a response proves remote bytes or permission to reclaim
local media. Recovery uses `Manifest.encode_descriptor/2` with the frozen
descriptor.

All fixtures/examples remain invented. Use Treehouse and no-mistakes for every
worktree/PR. Do not merge, deploy, enable recording, provision storage or run a
new live probe as part of this checkpoint. Keep #4913/#4915 open until their own
acceptance passes.
