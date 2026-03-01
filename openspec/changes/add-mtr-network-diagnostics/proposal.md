# Change: Add MTR Network Path Diagnostics to Agent

## Why

Ping checks tell operators IF a remote host is reachable and the overall round-trip time, but they cannot answer WHERE latency or packet loss is occurring along the network path. This is the single most common follow-up question when an ICMP check fires an alert. Today, operators must SSH into the agent host and run MTR manually — a workflow that doesn't scale across hundreds of distributed agents in hard-to-reach environments.

Implementing MTR as a native Go library inside the agent closes this diagnostic gap, provides continuous hop-by-hop visibility, and enables historical path analysis via CNPG/TimescaleDB — something even commercial tools like Datadog only recently added.

Ref: [GitHub Issue #1896](https://github.com/carverauto/serviceradar/issues/1896)

## What Changes

- **New Go package `go/pkg/mtr/`** — Pure-Go MTR implementation (ICMP, UDP, TCP probe modes) with no external binary dependency
- **New agent check type `"mtr"`** — Configured via `AgentCheckConfig` with settings for max hops, probe count, interval, protocol, and packet size
- **Proto additions** — New `MtrHopResult` and `MtrTraceResult` messages in `monitoring.proto` for structured hop-by-hop data
- **Agent integration** — MTR checks managed in PushLoop alongside existing ICMP checks, results pushed via standard gateway pipeline
- **On-demand support** — MTR runs triggerable via ControlStream command (`mtr.run`) for ad-hoc diagnostics
- **Privilege handling** — Raw socket usage with graceful fallback to unprivileged ICMP (SOCK_DGRAM on Linux) matching existing ICMP scanner patterns

## Impact

- Affected specs: NEW `mtr-diagnostics` capability spec
- Affected specs (modified): `agent-configuration` (new check type), `agent-connectivity` (new diagnostic capability)
- Affected code:
  - `go/pkg/mtr/` — New package (tracer, probes, statistics, DNS)
  - `go/pkg/agent/push_loop.go` — MTR check scheduling and result collection
  - `go/pkg/agent/control_stream.go` — On-demand MTR command handler
  - `proto/monitoring.proto` — New message types
  - `go/pkg/agent/types.go` — MTR configuration types

## Risks

- **Privilege requirements**: Raw sockets need CAP_NET_RAW or root. Mitigated by: (1) agent already requires this for ICMP scanner, (2) SOCK_DGRAM fallback on Linux
- **Resource consumption**: Continuous MTR probing generates more traffic than simple pings. Mitigated by: configurable intervals, probe counts, and max concurrent traces
- **Platform differences**: Raw socket behavior varies across Linux/macOS/BSD. Mitigated by: build tags and platform-specific socket handling (same pattern as existing `scan/` package)
