## Context
Agent configuration is currently delivered as a unary `GetConfig(AgentConfigRequest) returns (AgentConfigResponse)`. Large production configs can exceed default gRPC single-message limits before the agent has any chance to apply incremental or cached behavior.

ServiceRadar already has a robust chunked transport pattern for large agent-to-gateway status payloads. This change applies the same pattern in the reverse direction for gateway-to-agent config payloads.

## Goals
- Deliver large compiled configs without depending on larger unary gRPC message limits.
- Reuse existing chunking concepts and validation behavior where practical.
- Keep generated configs semantically identical after reassembly.
- Support rolling upgrades where old gateways or old agents still use unary `GetConfig`.

## Non-Goals
- Redesign the config compiler or dependency catalog.
- Split semantic config sections into independently applied partial configs.
- Change the agent's local override, cache, or apply precedence.

## Proposed Protocol
Add a server-streaming RPC:

```protobuf
rpc StreamConfig(AgentConfigRequest) returns (stream AgentConfigChunk) {}
```

Add a config-specific chunk message:

```protobuf
message AgentConfigChunk {
  string agent_id = 1;
  string config_version = 2;
  int64 config_timestamp = 3;
  bool not_modified = 4;
  bytes payload = 5;
  bool is_final = 6;
  int32 chunk_index = 7;
  int32 total_chunks = 8;
  string payload_sha256 = 9;
}
```

The payload is the protobuf-encoded `AgentConfigResponse` split into bounded chunks. `not_modified=true` responses may be represented as a single final chunk with empty payload and version metadata.

## Chunking Rules
- Use encoded protobuf byte size for chunk and stream budget checks, matching the status-stream tests.
- Keep a per-chunk budget lower than gRPC defaults so each chunk remains comfortably below single-message limits.
- Enforce a total stream budget to prevent unbounded config delivery.
- Require contiguous chunk indexes from `0..total_chunks-1`.
- Require exactly one final chunk and verify `payload_sha256` after reassembly.

## Agent Behavior
- Prefer `StreamConfig` for startup fetches and periodic refreshes.
- Reassemble and decode a full `AgentConfigResponse`, then pass it through the existing `applyConfigResponse` path.
- Fall back to unary `GetConfig` only when the gateway returns `Unimplemented`.
- Treat malformed, incomplete, oversized, or checksum-mismatched streams as config fetch failures and keep existing cached/fallback behavior.

## Gateway Behavior
- Compile or retrieve the same effective `AgentConfigResponse` used by unary `GetConfig`.
- For streamed requests, encode and chunk that response using shared helpers mirroring the status streaming byte-budget functions.
- Continue serving unary `GetConfig` for older agents.
- Emit logs/metrics for stream chunk count, total bytes, config version, and rejection reason without logging secret-bearing config content.

## Rollout
1. Add protobuf messages/RPC and regenerate Go/Elixir code.
2. Implement gateway-side chunking while keeping unary `GetConfig`.
3. Implement agent-side stream preference with `Unimplemented` fallback.
4. Add large-config tests that exceed unary default size but succeed over the stream.
