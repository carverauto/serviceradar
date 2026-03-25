## Context
`core-elx` now proves that bounded relay-derived media can be handed to Boombox and returned through the platform-owned analysis result contract. That proof currently runs inside the same BEAM runtime as the relay pipeline.

For production use, the next boundary should be an external executable worker. That makes worker rollout, failure isolation, and future language/runtime choices cleaner, while keeping relay ownership and result normalization in the platform.

## Goals
- Add an external executable worker that consumes bounded relay-derived media from `core-elx`.
- Keep the worker-facing media handoff narrow and deterministic enough for tests and operational control.
- Preserve the existing normalized analysis result contract and provenance model.
- Keep worker execution bounded so viewer playback remains the higher-priority path.

## Non-Goals
- Replacing the existing HTTP worker adapter.
- Turning the external worker into a second source of truth for relay lifecycle.
- Introducing continuous full-stream export in this change.

## Decisions
### Keep relay ownership in `core-elx`
`core-elx` remains the owner of relay sessions, branch lifecycle, and observability ingestion. The external worker only consumes bounded media artifacts that originate from the relay path.

### Keep the worker contract platform-owned
The worker may use Boombox internally, but the worker result boundary remains `camera_analysis_result.v1`. Adapter-specific details must not become part of the platform-owned schema.

### Start with one bounded transport
The first external worker path should prove one bounded handoff mode only. A simple and operationally explicit mode is better than prematurely supporting multiple transports.

## Risks
### Worker transport can sprawl
If the first worker contract is too flexible, it becomes harder to reason about cleanup, retries, and operator expectations. The initial handoff should be narrow.

### Externalization can weaken provenance
Moving the worker outside `core-elx` increases the chance of losing relay, branch, or worker identity unless enrichment stays centralized on the platform boundary.

### Analysis load can compete with playback
An external worker is easier to scale independently, but it is also easier to over-dispatch. Guardrails around sample interval, concurrency, and drops must remain tied to relay health.
