# VMS implementation handoff

## Current pickup

[Sealed-media upload #6007](https://github.com/carverauto/serviceradar/pull/6007)
is merged at `575dfc1f6b2d1efa2934487d934b1f3d9460b10d`. Its published head
`4c965ee8` passed all 19 checks. Core executed all 12 guarded targets and Web
all seven, uncached, with successful connection observation, teardown and
fixture-generation lease release. This includes all eight spool worker cases,
two media authority cases and both joined media-upload cases. Detailed evidence
and the accepted review decision are in [validation](validation.md#published-head-media-validation).

The [archive-publication checkpoint](archive-publication.md) consumes independent verified init and media
receipts, derives and verifies the recovery manifest, and publishes the archive
index under current ownership. Media verification alone is not archive
availability. Keep the existing one-shot media command; completion is a separate
bounded command and never rearms an attempted object operation.

[Archive publication #6047](https://github.com/carverauto/serviceradar/pull/6047)
is merged at `35078ce5b0e4233b30da59edec994ddd258ade87`. Its final head
`3bd7402a` passed all 20 checks. Core executed all 12 guarded targets and Web all
seven, uncached; suite, observer, teardown and lease-release statuses were zero.
The manifest-verification and index-publication subtasks are complete. See
[final validation](validation.md#published-head-archive-publication-validation).

The next bounded checkpoint is [authorized archive metadata](archive-metadata.md):
a fresh, camera-scoped inspection of one retained block. It reuses canonical
availability and exposes the frozen descriptor only while its proof chain remains
valid. Historical recording access has a separate permission approved by the
operator; live-video permission does not grant it. The implementation in this
branch still requires remote checks and published-head guarded Web execution.

[Registration #6000](https://github.com/carverauto/serviceradar/pull/6000) and
[spool identity #6004](https://github.com/carverauto/serviceradar/pull/6004) are
merged prerequisites. Registration returns an immutable unqualified binding;
the spool marker identifies a local storage lifetime. Neither provisions storage
or installs upload authority. The final media run also supplies the previously
missing handoff record for the eight guarded worker cases.

[Cloud media reservation #188](https://github.com/carverauto/serviceradar-control/pull/188)
retains allocation intent and a teardown fence; its last recorded state is an
open draft with five passing checks. Its provider ownership contract remains a
separate dependency. Synthetic product transport development can proceed without
claiming Cloud provisioning or live provider qualification.

Production recording stays disabled. Preserve the operator-confirmed live RTSP
path and every ownership, manifest, archive, intent and dispatch assertion.
All new endpoints, media and failure injections use invented synthetic data.

## Priority order

1. Finish the authorized single-block metadata read and its real HTTP/database
   checks. Then implement independently authorized byte-range delivery and
   bounded HLS/timeline windows. A metadata snapshot is never a byte-read grant;
   canonical proof conflicts must also deny future media reads. Preserve unknown
   clock mappings instead of inventing capture times.
2. Resolve Cloud's [allocation ownership gate](cloud-control-plane.md#allocation-ownership-gate)
   before provider creation. A matching name or successful create response does
   not prove ownership. [Issue #182](https://github.com/carverauto/serviceradar-control/issues/182)
   and [issue #183](https://github.com/carverauto/serviceradar-control/issues/183)
   own inventory, provisioning and preservation. Full qualification, provisioned
   spool identity and private workload installation precede hosted authority.
3. Complete playback, holds/retention, hosted lifecycle and optional workers in
   [tasks.md](tasks.md), following [Cloud ownership](cloud-control-plane.md).
4. Keep tasks 0.4 and 0.6 open: codec/RTCP/logical-byte experiments do not select
   production support, synchronization tolerances or capacity objectives. Complete
   synthetic security/failure/capacity acceptance before designated live acceptance.

## Evidence ledger

| Contract | Evidence | Remaining gate |
| --- | --- | --- |
| Runtime relay ownership | #5950/#5952/#5954 merged; #5954 head `89d50a7f`, guarded `7cbd7c77` passed all 12 targets | Deployment acceptance |
| Frozen archive and destination | #5955 merged at `88c5a324`; head `72a81f96`, guarded `0df082fa` passed all 12 targets | Bounded transport and publication are recorded below; hosted acceptance remains open |
| Immutable upload intent | #5960 merged at `29b30748`; guarded `853e4601` passed all 12 targets including five intent cases | Bounded transport and publication are recorded below; multipart reconciliation remains open |
| Durable dispatch observations | #5966 merged; final head `831e8893`, guarded Core `d85a7307` and Web `6aafb922` passed 12 and seven targets uncached, with all lifecycle statuses zero | Bounded authority and isolated init/media transport are recorded below; hosted qualification remains open |
| Qualification report | #5973 merged; 18 final checks passed. Six protocol cases; full remote `fc10c612` passes 459 targets after formatting, with two Swift platform skips; see [validation](validation.md) | Live evidence verification. Narrow installation is the init and media rows |
| Private qualification receipts | #5979 merged; 19 final checks passed. Core `42cf4965` and Web `8a15b4d4` executed all 12/seven guarded targets uncached; all lifecycle statuses zero, all five new DB cases included | Hosted configuration beyond the init and media rows |
| Deployment-scoped media authentication | #5983 merged; final head `66d22624` passed all checks. Core `59ceece3` and Web `f8b9178b` executed all 12/seven guarded targets; lifecycle statuses zero. HTTP shard 0: 819 tests + two properties, zero failures, both receipt cases traced | Hosted authority beyond the init and media rows |
| Durable recording stop | #5989 merged; 20 checks passed. Core `e00f8d32` and Web `2602f4c1` executed 12 and seven guarded targets; all lifecycle statuses zero. Five core cases covered by included owners; HTTP case explicitly traced | Full fleet drain and positive authority remain separate |
| Cloud media installation | #187 merged; all five checks passed; Timescale CI 3230 tests, zero failures, 10 skips, all 17 required cases enabled | Provider provisioning, qualification, isolated workload and lifecycle preservation |
| Init-object authority | #5996 merged; published head `447f594b` passed 19 checks; Core `551008e0` and Web `a4308a82` passed all 12/seven guarded targets with lifecycle exit statuses zero | Cloud provisioning/qualification and complete archive transport |
| Private archive registration | #6000 merged at `8974fcdd`; published head `e639b4fd` passed 19 checks; Web `1452ccca` executed all seven guarded targets uncached, including owning shard 0, with all lifecycle statuses zero; [validation](validation.md) retains the approved pre-push exception | Cloud-retained allocation identity and matching product receipt |
| Cloud media reservation | #188 remains an open draft; all five checks passed, including 3,241 tests with zero failures and 10 skips; local Dialyzer fails with 11 warnings also present on its exact base | Merge, allocation inventory and preservation-release workflow |
| Provisioned spool identity | #6004 merged at `0ba042ba` from head `30566cec`; [local marker contract](spool-lifetime.md) and [validation](validation.md#provisioned-spool-identity) | All eight worker cases passed in final media Core `773fd2dc`; Cloud volume/UUID association and full restart acceptance remain open |
| Sealed-media upload | #6007 merged at `575dfc1f`; head `4c965ee8` passed 19 checks. Core `773fd2dc` and Web `7fd98129` executed all 12/seven guarded targets uncached; all lifecycle statuses zero. [Byte-path contract](media-upload.md) | Publication is complete below; hosted qualification and deployment acceptance remain open |
| Archive publication | #6047 merged at `35078ce5`; final head `3bd7402a` passed 20 checks. Core `cb53539e` and Web `78dee076` executed all 12/seven guarded targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-publication-validation) | Authorized metadata and byte access; reconciliation, hosted qualification and deployment acceptance |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Start with [tasks.md](tasks.md), [archive metadata](archive-metadata.md),
[archive publication](archive-publication.md) and [Cloud ownership](cloud-control-plane.md).
The publication prerequisite is merged and its final database gates passed.
Finish this branch's metadata endpoint through no-mistakes, then require the
published-head Web owner to execute the real publication/read/conflict sequence
and permission controls. Core's existing proof and fencing suite remains required.
Keep every prior assertion and clean/re-query all committed fixture rows.

The metadata response is bounded to one source-matched block. Reload the user's
current authority, require recording-read plus inventory permission and use the
canonical proof owner. Only available blocks expose their immutable descriptor.
No provider I/O, local spool access, lease renewal or new readiness claim belongs
in a metadata read. Future playback must authorize every byte request separately.

Keep the isolated credential workload, original dispatch identities/deadlines,
late-conflict exclusion and post-stop DB-only publication unchanged. Cloud #188
remains unmerged and allocation ownership unresolved; product synthetic work
can proceed independently. Do not add a bucket allocator based on name or create
success. Inventory/preservation classification and an explicit adoption contract
are the next Cloud design work.

Use Treehouse with linked Bazel rc files, remote Bazel and no-mistakes. Do not
merge, deploy, enable recording, provision live storage or run live probes in
this checkpoint. Keep #4913/#4915 open until their own acceptance passes.
