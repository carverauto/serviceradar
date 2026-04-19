# Change: Restore live connected-agent runtime metadata in cluster settings

## Why
The `/settings/cluster` "Connected Agents" card can flap between showing a real version/platform and falling back to `Unknown version` / `Unknown platform` for the same active agent. Live investigation in `demo` showed the root cause is upstream of the LiveView: bare-metal agents can reconnect their control stream and continue pushing status without sending a fresh unary `Hello`, and the current `ControlStreamHello` payload does not include runtime metadata. As a result, the gateway tracker never receives live version/platform details for that session.

## What Changes
- Extend `ControlStreamHello` so agents include runtime metadata on control-stream connect, not only on unary `Hello`.
- Update the Go agent control-stream handshake to send version, hostname, operating system, architecture, and labels every time it establishes the control channel.
- Update the Elixir agent-gateway control-stream initialization path to track and persist the live runtime metadata it receives so `ServiceRadar.AgentTracker` remains authoritative for connected agents.
- Keep cluster settings rendering driven by live tracker state, with unknown placeholders only when the live gateway tracker genuinely lacks runtime metadata.

## Impact
- Affected specs: `agent-registry`
- Affected code: `proto/monitoring.proto`, `go/pkg/agent/control_stream.go`, `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_gateway_server.ex`, generated protobuf bindings, related tests
