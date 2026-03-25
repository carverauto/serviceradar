## Context
The current Boombox-backed adapter proves that relay-derived media can be attached to an optional media bridge without causing duplicate camera pulls, and that downstream results can preserve the same relay, branch, and worker provenance as other analysis adapters.

What remains unproven is a real worker path that actually consumes media from the Boombox branch and produces results through the normalized platform contract. The existing in-repo HTTP reference worker proves the contract, but it does not validate the Boombox media handoff itself.

## Goals
- Add an executable sidecar or worker path that consumes media from a relay-scoped Boombox branch.
- Keep the result path on the existing `camera_analysis_result.v1` contract.
- Preserve observability provenance across the full Boombox branch -> worker -> result ingestion path.
- Keep the implementation bounded and deterministic enough for reliable tests.

## Non-Goals
- Replacing the HTTP worker adapter.
- Replacing the relay ingest path or moving camera acquisition out of the platform.
- Delivering a production ML model in this change.

## Decisions
### Keep the contract platform-owned
The sidecar must return results through the same normalized result contract as the HTTP adapter path. Boombox-specific media details must not leak into the platform-owned analysis result schema.

### Prove one executable Boombox path first
The first sidecar path should prove one concrete Boombox media handoff shape end to end. It does not need to exhaustively support every Boombox transport or media packaging option.

### Keep branch ownership in `core-elx`
`core-elx` remains the owner of relay sessions, analysis branch lifecycle, and observability ingestion. The sidecar is a worker attached to that branch, not a new control plane.

## Risks
### Adapter-specific transport details can sprawl
If the sidecar contract depends too much on one Boombox output shape, it will be harder to evolve or add other worker modes later. The implementation should keep the worker-facing media boundary narrow and explicit.

### Media handoff can outgrow bounded guarantees
A worker that consumes continuous media can introduce backpressure or cleanup problems. The implementation must keep worker attachment, buffering, and teardown subordinate to viewer playback and relay stability.

### Result provenance can drift
It is easy for sidecar-generated detections to lose branch or worker identity if the enrichment point is not explicit. The result normalization boundary must stay centralized.
