## 1. Implementation

- [x] 1.1 Add `committed_chunk_indexes` to `GatewayStatusResponse` and regenerate the Go and Elixir bindings.
- [x] 1.2 Gateway: on a negative acknowledgement of an agent-retained stream, list the `chunk_index` of every committed chunk.
- [x] 1.3 Agent: drop the pending plugin results whose chunks committed, retry the rest in order, and fall back to whole-set retry when no index is listed.

## 2. Verification

- [x] 2.1 Go unit test: a partial acknowledgement retries only the uncommitted results; a whole-stream negative acknowledgement and out-of-range indexes retry the full set. The partial case fails against the pre-change agent.
- [x] 2.2 Gateway unit test: a three-chunk stream with an uncommitted middle chunk answers `received: false` with `committed_chunk_indexes: [0, 2]`. Fails against the pre-change gateway.
