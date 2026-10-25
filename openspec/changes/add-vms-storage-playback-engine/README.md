# VMS implementation handoff

## Current pickup

[Durable recording stop #5989](https://github.com/carverauto/serviceradar/pull/5989)
is merged at `b06d0b6b12e42519aa0bda8157692feedbffd12d`. All 20 checks passed,
including the six new guarded database cases. [Cloud media installation #187](https://github.com/carverauto/serviceradar-control/pull/187)
is merged at `a55f904cd9f929a58e133ca02c9b6dbe58323b73`; all five checks passed,
including its actual Timescale database suite. The Cloud installation proves
media authentication and chart persistence, not storage authority or readiness.

[Bounded init-object authority #5996](https://github.com/carverauto/serviceradar/pull/5996)
is merged at `ea7155e99f`. It installs a nonrenewable authority window and one
init-only dispatch grant. Its published head `447f594b` passed all 19 checks,
including guarded Core and Web database workflows; subsequent merges retain the
checkpoint. The source validation notes keep the original prepublication limits.

The current checkpoint adds [private archive registration](archive-registration.md)
through the existing deployment-bound media administrator listener. It reuses the
immutable destination parser and Ash registration action, returning a product
binding ID and digest with unqualified, unavailable status. It does not provision
provider resources or install upload authority. The new guarded Web database
case remains a published-head CI gate; unit routing/schema evidence is separate.

Production recording stays disabled. Preserve the operator-confirmed live RTSP
path and all existing ownership, manifest, archive, intent and dispatch
assertions. No rollout, live provider request, archive availability, recording
activation or local-media reclamation is introduced here. Provider I/O is outside
this metadata-registration checkpoint.

## Priority order

1. Validate and publish the private archive-registration checkpoint through
   no-mistakes, including its guarded Web database case. Cloud
   [issue #182](https://github.com/carverauto/serviceradar-control/issues/182) and
   [issue #183](https://github.com/carverauto/serviceradar-control/issues/183) own
   durable inventory, provisioning and preservation before teardown. Full
   qualification, provisioned spool identity and private workload installation
   are still required before Cloud can install init authority.
2. Add streaming media, multipart reconciliation, recovery-manifest verification
   and index publication.
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
| Init-object authority | #5996 merged; published head `447f594b` passed 19 checks; Core `551008e0` and Web `a4308a82` passed all 12/seven guarded targets with lifecycle exit statuses zero | Cloud provisioning/qualification and complete archive transport |
| Private archive registration | Focused `9dea8457`: 833 unit tests, zero failures, 223 DB cases excluded; full remote `dad78500`: 460 targets passed, two platform skips; [wire contract](archive-registration.md), [validation](validation.md) | No-mistakes publication and the new guarded Web database case |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [qualification-report.md](qualification-report.md),
[qualification-receipts.md](qualification-receipts.md), [media-authentication.md](media-authentication.md),
[recording-control.md](recording-control.md), [init-authority.md](init-authority.md),
[archive-registration.md](archive-registration.md), [upload-intent.md](upload-intent.md),
[upload-dispatch.md](upload-dispatch.md) and
the current diff. Finish no-mistakes validation/publication and actual guarded
Web database execution for private archive registration. Cloud must retain the
original provisioning intent and product binding receipt before progressing to
qualification or installation. Registration itself never authorizes provider I/O.
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
