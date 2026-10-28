# VMS implementation handoff

## Current pickup

[Archive player #6096](https://github.com/carverauto/serviceradar/pull/6096)
is merged. The [published-head evidence](validation.md#published-head-archive-player-validation)
owns the final validation results, executor commits, corrected first-run failure
and approved prepublication database deferral.

The [separate recordings page and single-block HLS player](archive-player.md)
uses the merged [publication inventory](archive-discovery.md). Client fragment
requests are serialized; interrupted seeks and switches may require explicit
retry while the existing single reader retires old work. Unknown capture UTC
remains unknown; publication order is not a wall-clock timeline.

[Archive publication](archive-publication.md), [media upload](media-upload.md),
[registration](archive-registration.md) and [spool identity](spool-lifetime.md)
are merged prerequisites. Their detailed evidence remains below. None enables
recording or qualifies a live provider.

[Cloud reservation #188](https://github.com/carverauto/serviceradar-control/pull/188)
is merged with its immutable reservation and sticky preservation fence retained.
Merged [PR #6126](https://github.com/carverauto/serviceradar/pull/6126) supplies a
[default-disabled reader installation](../../../docs/archive-init-storage.md#separate-archive-reader-installation)
as a prerequisite for the requested deployment acceptance. It does not start
recording or claim that archives are available. Allocation ownership is unresolved. The
[ownership gate](cloud-control-plane.md#allocation-ownership-gate) requires
operation-bound creation proof or a separately specified and authorized adoption
workflow before provider allocation or readiness.

The private [bounded local capture](capture-once.md) entry point is now available
for explicit opt-in; that reference owns its configuration, limits and receipt
contract. Recording remains disabled by default, and this checkpoint does not
authorize deployment or live capture. Preserve the confirmed live RTSP path and
every ownership, manifest, archive, intent and dispatch assertion. New media,
identifiers and failure injections are independently invented synthetic data.

## Priority order

1. Complete provider qualification and persistent spool installation before
   attempting deployment acceptance of the merged reader and bounded capture. Preserve all
   19 qualification checks, provisioned spool identity and fresh per-purpose
   authorities; a chart switch cannot substitute for them. The proposed
   [persistent-spool installation](../add-persistent-camera-spool/proposal.md)
   scopes per-replica storage, controlled controller conversion and Cloud restore
   changes. Its architecture choice remains pending; it does not enable capture.
   Cloud #188 is merged; its independent next scope remains the
   [read-only reservation status](cloud-control-plane.md#next-bounded-cloud-checkpoint)
   in the operator environment console, without provider mutation.
2. Resolve Cloud's [allocation ownership gate](cloud-control-plane.md#allocation-ownership-gate)
   before provider creation. A matching name or successful create response does
   not prove ownership. [Issue #182](https://github.com/carverauto/serviceradar-control/issues/182)
   and [issue #183](https://github.com/carverauto/serviceradar-control/issues/183)
   own inventory, provisioning and preservation. Full qualification, provisioned
   spool identity and private workload installation precede hosted authority.
3. Complete provisional local playback, capture-time timeline, holds/retention,
   hosted lifecycle and optional workers in [tasks.md](tasks.md). Every request
   reauthorizes independently; neither inventory nor a fetched plan grants later
   access. Preserve unknown clock mappings.
4. Keep tasks 0.4 and 0.6 open: codec/RTCP/logical-byte experiments do not select
   production support, synchronization tolerances or capacity objectives. Complete
   synthetic security/failure/capacity acceptance before designated live acceptance.

The requested [follow-ups](tasks.md) remain unchecked: task 1.8 adds a bounded
per-viewer bitrate/health graph with source-ingest rate labeled separately;
task 3.7 adds low-cost object/person detection and authorized recent-detection
thumbnails/clip links. Reuse the existing shared ingest and Boombox analysis
contract. Its current keyframe labels, dimensions and capture summaries are not
semantic detections. Benchmark small local models, sampling and CPU/GPU costs
before choosing a default; analysis overload must not stall live or recording
consumers. These are future implementation tasks, not part of provider diagnostics.

The current checkpoint adds an opt-in
[encryption-policy diagnostic](../../../build/media/provider-probe.md#encryption-policy-diagnostic).
It pairs all four denials with compliant writes and policy inspection, retaining
exact cleanup authority. Task 0.5 remains open: synthetic TLS validation tests
the diagnostic, not a live provider or the mediated workload boundary. Recording
and reader installation in a deployment still require the authorities above.

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
| Cloud media reservation | #188 merged at `349e37bb` from head `1f0297a0`, after security maintenance #189. Final PR CI and [post-merge main CI](https://github.com/carverauto/serviceradar-control/actions/runs/40599450501) each passed 3,241 Timescale tests with zero failures and 10 skips, 294 contract tests, both dependency audits and image build; independent scratch absence checks returned zero. CI skipped Dialyzer; prior historical warnings are not a new pass | Bounded reservation visibility, allocation ownership and preservation-release workflow |
| Provisioned spool identity | #6004 merged at `0ba042ba` from head `30566cec`; [local marker contract](spool-lifetime.md) and [validation](validation.md#provisioned-spool-identity) | All eight worker cases passed in final media Core `773fd2dc`; Cloud volume/UUID association and full restart acceptance remain open |
| Sealed-media upload | #6007 merged at `575dfc1f`; head `4c965ee8` passed 19 checks. Core `773fd2dc` and Web `7fd98129` executed all 12/seven guarded targets uncached; all lifecycle statuses zero. [Byte-path contract](media-upload.md) | Publication is complete below; hosted qualification and deployment acceptance remain open |
| Archive publication | #6047 merged at `35078ce5`; final head `3bd7402a` passed 20 checks. Core `cb53539e` and Web `78dee076` executed all 12/seven guarded targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-publication-validation) | Byte access is covered by [archive reads](archive-reads.md); reconciliation, hosted qualification and deployment acceptance remain open |
| Authorized archive metadata | #6055 merged at `ca8ad4e2`; head `a586219c` passed 19 checks. Core `5c6abc7a` and Web `a05a66e9` executed all 12/seven targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-metadata-validation) | Byte delivery is covered by [archive reads](archive-reads.md); timeline and hosted acceptance remain open |
| Authorized archive bytes | #6060 merged at `9a68975d`; head `cf918169` passed 19 checks. Core `fc501f97` and Web `88ddf619` executed all 12/seven targets uncached with successful lifecycle cleanup; [validation](validation.md#published-head-archive-fragment-read-validation) | [Player status](archive-player.md#validation-boundaries); timeline and hosted acceptance |
| Bounded archive playlists | #6071 merged at `80af80b6`; head `240e6ff7` passed 19 checks. Core `44a5a8ab` and Web `89379230` executed all 12/seven guarded targets uncached; all lifecycle statuses zero. Real HTTP HLS consumer passed with 30 selected-window frames and 90 full-stream frames | [Discovery](archive-discovery.md) and [player status](archive-player.md#validation-boundaries); provisional local delivery and hosted acceptance |
| Bounded publication inventory | #6089 merged at `e0635e06`; head `76d4c063` passed 19 checks. Core `90e51d24` and Web `f755112a` executed all 12/seven guarded targets uncached; all lifecycle statuses zero. Core owner 324 tests and Web owner 836 tests plus two properties passed | [Player status](archive-player.md#validation-boundaries); capture-time timeline and hosted acceptance |
| Per-camera archive player | #6096 merged; [final validation](validation.md#published-head-archive-player-validation) | [Remaining acceptance boundaries](archive-player.md#validation-boundaries), broader browser/codec support, capture-time timeline and hosted acceptance |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics, including the separate encryption-policy suite; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; live policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Start with [tasks](tasks.md), the
[reader installation](../../../docs/archive-init-storage.md#separate-archive-reader-installation)
and [Cloud ownership](cloud-control-plane.md).
Cloud #188 and its separate security dependency #189 are merged. Preserve every
reservation, preservation and runtime assertion.
Product #6096's final database gate is complete; its approved prepublication
deferral and first failed run remain in the validation history.

The independent Cloud scope is bounded reservation visibility in the existing
operator environment console, following the
[Cloud checkpoint](cloud-control-plane.md#next-bounded-cloud-checkpoint), which
owns the scope and acceptance boundaries.

The [archive reader](archive-reads.md) owns isolated credentials, byte selectors
and authorization before byte release. The [playlist contract](archive-playlists.md)
owns bounded windows and relative resource URLs. Inventory is a discovery
snapshot, never a future-access grant or capture-time claim.

The recordings page/player is merged without acquiring a live relay. Its
pinned HLS client passed seeking, cancellation and explicit-retry browser checks;
server admission remains unchanged. Actual publication/authentication and public
HTTP cancellation bodies executed on the final published-head CI checkout.
Keep local provisional reads, retention, provider qualification and hosted
enablement distinct. Matching names, GET-before-create and successful create
responses cannot authorize bucket adoption or cleanup.

Use Treehouse with linked Bazel rc files, remote Bazel and no-mistakes. Do not
merge, deploy, enable recording, provision live storage or run live probes in
this diagnostic checkpoint. Plan the requested deployment activation
against the remaining qualification and authority gates separately. Keep
#4913/#4915 open until their own acceptance passes.
