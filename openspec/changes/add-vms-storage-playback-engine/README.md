# VMS implementation handoff

## Current pickup

[Dispatch PR #5966](https://github.com/carverauto/serviceradar/pull/5966) is merged
at `df8a8fe2e20d5f3220483200e27fcc74b6872e14`. Its final head `831e8893`
passed all 20 checks, including fresh guarded Core and Web-NG suites. The
[Cloud storage plan #185](https://github.com/carverauto/serviceradar-control/pull/185)
is merged at `5a46b36e51e2428097f6202ce2f16678e9491780`; that PR is planning only.

The current checkpoint defines the bounded
[qualification report format](qualification-report.md). Parsing preserves
observations and computes canonical content identity. It grants no storage
permission and installs no authority. Destination registration remains
unqualified; credential custody, authenticated configuration and current
qualification enforcement must precede provider I/O.

Production recording stays disabled. Preserve the operator-confirmed live RTSP
path and all existing ownership, manifest, archive, intent and dispatch
assertions. No rollout, provider request, archive availability, recording
activation or local-media reclamation is introduced here.

## Priority order

1. Finish the shared desired/applied contract around the qualification report:
   authenticated origin/deployment, exact binding/revision matching, conservative
   freshness, revocation and isolated storage-service credential authority. Cloud
   [issue #182](https://github.com/carverauto/serviceradar-control/issues/182) and
   [issue #183](https://github.com/carverauto/serviceradar-control/issues/183) also
   own provisioning and preservation before teardown.
2. Implement one bounded init-object conditional PUT and exact byte verification
   through that authority, outside CNPG transactions. Then add streaming media,
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
| Qualification report | Six new protocol cases; full remote `fc10c612` passes 459 targets after formatting, with two Swift platform skips; see [validation](validation.md) | Authenticated desired/applied contract, evidence verification and current authority enforcement |
| Media experiments | #5959 merged at `ad424ac6`; codec, RTCP and logical-byte experiments; 120-second fixture deadlines and direct `pion/rtcp` dependency retained | Production audio/HEVC, trusted UTC and measured deployment objectives |
| Provider/Cloud | Synthetic conditional-write/SSE diagnostics; both prior live exercises cleaned and rechecked; Cloud planning #185 merged | Live readiness remains failed; policy-denial, Object Lock and full provider qualification remain unproved |

[Validation history](validation.md) retains invocation links, exact-head results,
negative controls and prepublication exceptions. [Choices](choices.md) records
implementation decisions. Neither a planning merge nor a report parser completes
runtime or live acceptance tasks.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [qualification-report.md](qualification-report.md),
[upload-intent.md](upload-intent.md), [upload-dispatch.md](upload-dispatch.md) and
the current diff. The immediate dependency is authenticated installation and
expiry/revocation of storage authority, not another untrusted `ready` flag.
Do not mistake the report format or a dispatch marker for permission to send.

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
