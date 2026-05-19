# Change: Add streamed agent config delivery

## Why
Production agents can receive compiled configurations larger than the unary gRPC message limit. A recent production config response was about 7.4 MiB and failed with `ResourceExhausted` at the agent because unary `GetConfig` relies on single-message delivery.

## What Changes
- Add a gateway-to-agent streamed config fetch path that chunks `AgentConfigResponse` payloads instead of returning one large unary response.
- Reuse the existing streaming status machinery patterns in the opposite direction: chunk metadata, final markers, encoded byte-size budgets, ordering validation, and reassembly tests.
- Keep unary `GetConfig` available for backward compatibility, while new agents prefer streamed config fetch and fall back only when the gateway does not implement the streamed RPC.
- Preserve config versioning, `not_modified`, polling intervals, control-stream config acknowledgements, and existing apply/cache behavior after reassembly.

## Impact
- Affected specs: `agent-config`, `agent-configuration`
- Affected code: `proto/monitoring.proto`, generated protobuf code, `go/pkg/agentgateway`, `go/pkg/agent`, `elixir/serviceradar_agent_gateway`
- Operational impact: mixed-version gateway/agent deployments must remain safe during rolling upgrades.
