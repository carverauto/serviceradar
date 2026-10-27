# VMS implementation handoff

## Current pickup

[Authorized archive metadata #6055](https://github.com/carverauto/serviceradar/pull/6055)
is merged at `ca8ad4e2b106c120824ebf35fcd256ce8a69f387`. Its final head
`a586219c` passed all 19 checks. Core executed 12 guarded targets and Web seven,
uncached, with successful observer, teardown and generation release. The
[validation ledger](validation.md#published-head-archive-metadata-validation)
retains the approved prepublication exception and the actual execution evidence.

The current checkpoint is [authorized archive fragment reads](archive-reads.md).
It builds on canonical publication and separate recording-read permission, with
fresh checks before provider I/O and before byte delivery. Its runtime and
joined synthetic validation are in progress; compilation does not complete the
required published-head Core/Web database gates.

[Archive publication](archive-publication.md), [media upload](media-upload.md),
[registration](archive-registration.md) and [spool identity](spool-lifetime.md)
are merged prerequisites. Their detailed evidence remains below. None enables
recording or qualifies a live provider.

[Cloud reservation #188](https://github.com/carverauto/serviceradar-control/pull/188)
remains an open draft at `9caedaa8`, with five passing checks. Allocation
ownership is unresolved. Synthetic product work can proceed independently;
Cloud must resolve ownership and preservation before provisioning or readiness.

Production recording stays disabled. Preserve the confirmed live RTSP path and
every ownership, manifest, archive, intent and dispatch assertion. New media,
identifiers and failure injections are independently invented synthetic data.

## Priority order

1. Complete the isolated archive fragment reader and its real HTTP/database
   gates. Then implement bounded HLS/timeline windows and provisional local
   delivery. Every request reauthorizes independently; neither metadata nor a
   previously fetched plan grants later access. Preserve unknown clock mappings.
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
| Archive publication | #6047 merged at `35078ce5`; final head `3bd7402a` passed 20 checks. Core `cb53539e` and Web `78dee076` executed all 12/seven guarded targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-publication-validation) | Byte access; reconciliation, hosted qualification and deployment acceptance |
| Authorized archive metadata | #6055 merged at `ca8ad4e2`; head `a586219c` passed 19 checks. Core `5c6abc7a` and Web `a05a66e9` executed all 12/seven targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-metadata-validation) | Byte delivery, timeline and hosted acceptance |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Start with [tasks](tasks.md), [archive reads](archive-reads.md) and
[Cloud ownership](cloud-control-plane.md). Finish the current fragment-read
checkpoint through remote validation and no-mistakes, preserving every existing
assertion. Require the actual published-head Core proof owner and Web joined
publication/read tests to execute with successful fixture cleanup.

Read credentials stay in a separate, nondistributed process. Browser input is
only camera UUID, block UUID and init/fragment selector. Compare a freshly
rederived canonical plan and current human authority before releasing bounded,
digest-verified bytes. Reads must work independently of recording stop and
expired upload grants. No arbitrary object-range or URL endpoint is permitted.

Next add bounded HLS/timeline windows; keep local provisional reads, retention,
provider qualification and hosted enablement distinct. Cloud #188 remains
unmerged: inventory/preservation classification can proceed, but matching names
or create success cannot authorize bucket adoption or cleanup.

Use Treehouse with linked Bazel rc files, remote Bazel and no-mistakes. Do not
merge, deploy, enable recording, provision live storage or run live probes in
this checkpoint. Keep #4913/#4915 open until their own acceptance passes.
