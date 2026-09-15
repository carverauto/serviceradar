## Context
The producer timer is hourly; `cadence` (default 24h) is supposed to skip the collection walk. `CacheCanSkipFullScan` currently returns false whenever `ServerReconcileRequestedAt` is set and there is no pending upload. That conflates "core wants a full SBOM anchor" with "re-walk the host".

On a Kubernetes worker this produced a full ScaLibr walk every hour (`full_scan_count` in the hundreds) with `upload_reason=changed` and metadata `reason=server_reconcile_floor` even when the package set hash was unchanged.

A second loop keeps the flag armed: ingest ORs `reconcile_floor_due` on the current scan row, and duplicate/hash-noop acks re-send the floor directive. The agent applies that directive *before* `MarkUploadSucceeded`, so a `now` stamp is not cleared by the ack of the older pending reconcile.

## Goals / Non-Goals
- Goals:
  - Hourly timer + 24h cadence collects at most once per cadence when sources are unchanged.
  - Reconcile floor still forces a full changed upload (full SBOM, no package delta) of the cached set.
  - Floor directives are one-shot until a later unchanged streak or age floor is crossed again.
- Non-Goals:
  - Changing the hourly timer, default cadence, or floor constants (24 scans / 7 days).
  - Skip-directory contents (separate change).
  - Counting heartbeats as unchanged scans.

## Decisions
- Decision: Split `CacheCanSkipCollection` (cadence, identity, source mtimes, force-fresh) from `CacheNeedsReconcileUpload` (outstanding floor, no pending upload). `CacheCanSkipFullScan` remains "skip collection *and* no reconcile upload" so `RecordCachedScan` stays honest.
- Decision: When collection can be skipped and a reconcile upload is needed, replay `cache.Packages` through `FinalizeFullScan` with the cached hashes. Do not walk. If the cache has no package set/hashes, fall through to a real collection.
- Decision: Ingestor short-circuit and hash-noop results SHALL emit `reconcile_floor` only when this observation *newly* crosses the floor (`reconcile_floor_due?` true and the current row was not already due).
- Decision: Agent upload-ack applies `MarkUploadSucceeded` first, then `MarkServerReconcileRequested`. A floor directive on a response that also acks a full changed upload is ignored (that upload *was* the reconcile).
- Alternatives considered:
  - Drop reconcile from `CacheCanSkipFullScan` and emit unchanged during floor. Rejected: core would never get the full-anchor upload the floor exists for.
  - Keep forcing a walk. Rejected: that is the incident.

## Risks / Trade-offs
- Replayed SBOM bytes may not byte-match the original artifact; hashes are reused from cache so core treats it as the same package set. That matches today's reconcile test (same hashes, full changed upload).
- If cache packages were lost, we collect for real. Correct and rare.

## Migration Plan
- No schema migration. Behavior changes on agent/add-on + core ingest.
- Bump `scalibr-endpoint-inventory` because `go/pkg/scalibrinventory` and `go/pkg/endpointinventory` are in that add-on's version-bump paths.
- Rollback: previous add-on + core restore hourly walks and sticky floor.

## Open Questions
- None blocking.
