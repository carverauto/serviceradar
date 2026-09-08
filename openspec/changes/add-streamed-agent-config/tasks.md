## 1. Protocol
- [x] 1.1 Add `AgentConfigChunk` and `StreamConfig` to `proto/monitoring.proto`.
- [x] 1.2 Regenerate Go and Elixir protobuf bindings.
- [x] 1.3 Confirm generated service interfaces preserve existing unary `GetConfig`.

## 2. Gateway
- [x] 2.1 Add config chunking helpers that reuse the status-stream validation approach.
- [x] 2.2 Implement `StreamConfig` in `serviceradar_agent_gateway`.
- [ ] 2.3 Add gateway tests for chunk sizing, final chunk validation, not-modified responses, and oversized config rejection.
- [x] 2.4 Add safe logs/metrics for config stream bytes and chunk count without config payload contents.

## 3. Agent
- [x] 3.1 Add a streamed config fetch method in `go/pkg/agentgateway`.
- [x] 3.2 Prefer streamed config in the agent config refresh path.
- [x] 3.3 Fall back to unary `GetConfig` only for `Unimplemented` gateways.
- [x] 3.4 Add reassembly validation for ordering, final chunk, total chunks, stream budget, and checksum.
- [x] 3.5 Route decoded responses through the existing apply/cache path.

## 4. Verification
- [x] 4.1 Add Go tests for successful large streamed config reassembly and unary fallback.
- [x] 4.2 Add Elixir tests for streaming a config larger than unary defaults.
- [x] 4.3 Run targeted Go tests for `go/pkg/agentgateway` and agent config refresh.
- [x] 4.4 Run targeted Elixir tests for `elixir/serviceradar_agent_gateway`.
- [ ] 4.5 Validate mixed-version behavior in a local or demo rollout plan before release.
