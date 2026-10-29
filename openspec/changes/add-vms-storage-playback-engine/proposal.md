# Change: Cloud-ready VMS storage, playback and media workers

Tracking: [ServiceRadar #4913](https://github.com/carverauto/serviceradar/issues/4913)
and [#4915](https://github.com/carverauto/serviceradar/issues/4915).
Source: [PRD added 2026-10-23](https://github.com/carverauto/serviceradar/issues/4913#issuecomment-6357595299).

Status: approved in [PR #5945](https://github.com/carverauto/serviceradar/pull/5945);
implementation is in progress. Engineering and release gates remain open.
See the [implementation handoff](README.md) for the current pickup point.

## Why

The PRD expands the earlier recording foundation into a storage and playback
product: packed CMAF objects, immediate local playback, archive recovery, evidence
preservation, and optional accelerated search and derived video. Cloud delivery
also needs a provisioning and security contract with the SaaS control plane.

The original `add-camera-recording-storage` and
`add-recording-playback-lifecycle` proposals were committed on staging through
`b103f2604aeb3e3281df6e9247035ab5d035eea3`, with unchecked implementation
checklists. This proposal consolidates them and preserves their acceptance
contracts. It removes their pending directories rather than archiving
unimplemented work as shipped. Their source remains in that Git revision.
[PRD traceability](prd-traceability.md) records the disposition of every FR.

## What Changes

- Retain one upstream camera/profile ingest with independent viewer, recorder and
  analysis leases, fenced ownership, bounded buffering and explicit clock quality.
- Add packed fMP4 recording blocks and CNPG/Ash indexes, with separate provisional
  local readability and verified archival publication.
- Add authorized HLS byte-range playback, local cache, bounded timeline queries,
  evidence holds, exports and recoverable retention.
- Define hosted resource provisioning, private storage, credential custody,
  versioned runtime configuration, quotas, suspension and deletion contracts.
- Define optional GPU worker admission and durable work delivery. Evaluate
  transcription, semantic search, thumbnails, composition and metadata overlays.
- Modify the existing camera-streaming idle contract so active recording or
  analysis consumers prevent viewer-idle teardown.

## Scope and sequencing

| Stage | Deliverable | Exit gate |
| --- | --- | --- |
| P0 | Compatibility, durability, provider and capacity experiments | Measured format/codec, recovery, authorization and cost evidence |
| P1 | H.264 recording, packed archive, local live-edge access, HLS seeking | Synthetic end-to-end recording and failure injection; private storage prerequisites |
| P2 | Hosted provisioning, lifecycle, cache, audio, optional HEVC/replay and GPU execution | Control-plane issues complete; retention races, isolation and capacity proved |
| P3 | Search, transcripts, composition and hybrid edge | Separate detailed search/edge contracts and measured worker support |

Cloud contracts are designed now; the manual test environment does not prove
automated SaaS provisioning. P1 includes live-edge playback to resolve the PRD's
inconsistent placement of that feature in both MVP and Phase 2. No one-to-two-week
delivery promise is adopted before P0.

`add-edge-recording-archive` / #4914 retains disconnected capture, local
filesystem buffering, offline credential windows and archive receipts.
`add-scalable-camera-recording-plane` extends this foundation with independent
recorder pools and cloud + S3, on-prem + local, and on-prem + S3 modes. It removes
JetStream media staging and makes S3 optional for customer-operated storage.
It depends on this foundation and is not replaced. Spatial resources/observations
remain owned by their existing proposals. Neither #4774 nor live-view delivery is
blocked by VMS. Do not close #4913 or #4915 for merging planning documents.

## Impact

- Specs: `camera-streaming` (modified), `camera-recording`,
  `vms-cloud-resources`, `vms-media-workers` (added).
- Runtime: camera relay/agent/gateway contracts, core media workers and Ash
  resources, web-ng playback APIs/player, Helm resources and storage configuration.
- SaaS: [serviceradar-control](https://github.com/carverauto/serviceradar-control)
  provisioning, storage provider/custody, runtime values, offering/quotas,
  resource inventory and lifecycle. See [cloud handoff](cloud-control-plane.md).
- No application `tenant_id`, shared runtime database or per-customer routing is
  introduced. SaaS tenancy stays in the control plane; each runtime remains a
  dedicated deployment.
- Media remains separate from telemetry, CNPG backup and warehouse buckets.
  Camera credentials remain in the unified credential inventory.

## Review material

[Design](design.md), [cloud ownership and issue scopes](cloud-control-plane.md),
[GPU and plugin evaluation](media-workers.md), [tasks and acceptance](tasks.md).
