## Context
The current analysis pipeline proves the contract with a bounded HTTP worker adapter and a deterministic reference worker. That is enough to validate the platform boundary, but it is not the best shape for richer media-processing pipelines.

Boombox is a good candidate for an optional adapter because it can sit on the platform side of the relay boundary and bridge media toward external processing systems without changing the relay/session model or requiring browsers or workers to talk directly to edge cameras.

## Goals
- Add a Boombox-backed adapter as an optional analysis transport.
- Reuse the existing relay-scoped analysis branch model.
- Preserve the normalized result-ingestion contract and observability provenance.

## Non-Goals
- Replacing the existing HTTP adapter.
- Making Boombox mandatory for all analysis paths.
- Replacing the relay ingest path or moving camera acquisition out of the platform.

## Decisions
### Keep adapter plurality
Boombox should be one adapter path alongside the existing HTTP worker adapter. The worker contract and result ingestion remain platform-owned.

### Keep viewer playback higher priority
Boombox-backed analysis must remain bounded and subordinate to viewer playback, just like the existing analysis adapters.

### Preserve observability identity
Derived results from Boombox-backed analysis must preserve the same relay session, branch, and worker provenance as other analysis paths.

## Risks
### Adapter complexity
A richer media bridge can blur the boundary between analysis transport and relay ownership. The implementation must stay relay-attached and platform-local.

### Transport sprawl
If Boombox-specific concepts leak into the core analysis contract, future adapters become harder to add.
