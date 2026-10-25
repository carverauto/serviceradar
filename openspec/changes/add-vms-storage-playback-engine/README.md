# VMS implementation handoff

## Current pickup

The current byte-path checkpoint adds explicit
[sealed-media upload](media-upload.md) through the isolated storage service,
building on [provisioned spool identity](spool-lifetime.md). Its caller accepts
only a frozen block ID, uses media-specific authority and verifies exact remote
bytes. Success means `media_verified`; recovery-manifest verification and fenced
index publication still precede archive availability. Published-head guarded
database execution remains required for both checkpoints.

[Private archive registration #6000](https://github.com/carverauto/serviceradar/pull/6000)
is merged at `8974fcddd7039648085898b7fb9319d55898a7c8`. Its published head
`e639b4fd` passed all 19 checks, including the seven guarded Web database targets
and successful teardown and fixture-generation lease release. The approved
pre-push Test exception remains in the validation record; final-head database
execution satisfied its condition. The [registration contract](archive-registration.md) returns an
immutable binding ID and digest with unqualified, unavailable status.

[Cloud media reservation #188](https://github.com/carverauto/serviceradar-control/pull/188)
is an open draft, not a merged prerequisite. It retains immutable allocation
intent and a sticky teardown fence before provider allocation; all five CI
checks passed. Local Dialyzer fails with the same 11 emitted warnings on the exact
base and PR head; CI skips Dialyzer. Neither registration nor reservation
provisions storage or installs upload authority.

Production recording stays disabled. Preserve the operator-confirmed live RTSP
path and all existing ownership, manifest, archive, intent and dispatch
assertions. Product transport development uses isolated synthetic endpoints;
live provider qualification and deployment acceptance remain separate gates.

## Priority order

1. Finish no-mistakes publication and actual guarded Core/Web database execution
   for spool identity and sealed-media upload. Then obtain or consume independent
   init verification, write and verify the recovery manifest from the frozen
   descriptor, and publish the index idempotently under current ownership.
   Only the complete verified archive and published index expose availability.
   Init authority never authorizes media. Multipart reconciliation remains open.
2. Resolve Cloud's [allocation ownership gate](cloud-control-plane.md#allocation-ownership-gate)
   before adding a provider-creation worker. A matching name or successful
   create response cannot prove ownership. Cloud
   [issue #182](https://github.com/carverauto/serviceradar-control/issues/182) and
   [issue #183](https://github.com/carverauto/serviceradar-control/issues/183) own
   inventory, provisioning and preservation before teardown. Retain exact
   operation/destination identity, uncertain outcomes and the product binding
   receipt once the provider proof contract is established. Full qualification,
   provisioned spool identity and private workload installation are required
   before Cloud can install upload authority. This does not block synthetic
   product transport development.
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
| Private archive registration | #6000 merged at `8974fcdd`; published head `e639b4fd` passed 19 checks; Web `1452ccca` executed all seven guarded targets uncached, including owning shard 0, with all lifecycle statuses zero; [validation](validation.md) retains the approved pre-push exception | Cloud-retained allocation identity and matching product receipt |
| Cloud media reservation | #188 remains an open draft; all five checks passed, including 3,241 tests with zero failures and 10 skips; local Dialyzer fails with 11 warnings also present on its exact base | Merge, allocation inventory and preservation-release workflow |
| Provisioned spool identity | [Local marker contract](spool-lifetime.md), real filesystem negative controls and source validation in [validation](validation.md#provisioned-spool-identity) | Published-head `integration_tests_serial_4` with all eight synthetic worker cases, full selected Core and Web database lifecycles, cleanup and fixture lease release; Cloud volume/UUID association |
| Sealed-media upload | [Byte-path contract](media-upload.md); synthetic TLS/CONNECT, streaming and lifecycle checks | Final published-head Core authority cases and both joined Web database cases; complete manifest/index publication |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Start with [tasks.md](tasks.md), [media upload](media-upload.md),
[spool lifetime](spool-lifetime.md) and [Cloud ownership](cloud-control-plane.md).
Registration is merged and its guarded Web database execution passed. Finish
the spool/media publication gates, preserving their recorded limits. The next
product pass obtains or consumes independent init verification, verifies the
recovery manifest and publishes the archive index; reuse the existing
[upload intent](upload-intent.md) and [dispatch](upload-dispatch.md) owners.
The media caller currently releases its lease after media verification and has
no production init caller or scheduler. Keep publication retries fenced and do
not rearm an attempted object operation. Cloud's
new-allocation proof remains unresolved; do not add queued work that can only
report an unsupported provider contract. Registration never authorizes provider
I/O, and a reservation never proves owned storage.
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
worktree/PR. Exercise real transport against isolated synthetic endpoints. Keep
live provider calls and deployment acceptance separate; do not merge, deploy,
enable recording, provision live storage or run a new live probe in these passes.
Keep #4913/#4915 open until their own
acceptance passes.
