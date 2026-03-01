# Change: Add MTR Network Path Diagnostics to Agent

## Why

Ping checks tell operators IF a remote host is reachable and the overall round-trip time, but they cannot answer WHERE latency or packet loss is occurring along the network path. This is the single most common follow-up question when an ICMP check fires an alert. Today, operators must SSH into the agent host and run MTR manually — a workflow that doesn't scale across hundreds of distributed agents in hard-to-reach environments.

Implementing MTR as a native Go library inside the agent closes this diagnostic gap, provides continuous hop-by-hop visibility, and enables historical path analysis via CNPG/TimescaleDB. Results are enriched at collection time with MPLS labels, ASN/org data, and reverse DNS — stored as a complete dataset so downstream consumers never need to re-enrich. Path data feeds into the God View topology visualization via Apache AGE, giving operators a live, interactive view of network paths alongside the existing L2/L3 topology.

Ref: [GitHub Issue #1896](https://github.com/carverauto/serviceradar/issues/1896)

## What Changes

### Agent / Go

- **New Go package `go/pkg/mtr/`** — Pure-Go MTR implementation (ICMP, UDP, TCP probe modes) with MPLS label extraction, IPv4/IPv6 from day one
- **New agent check type `"mtr"`** — Configured via `AgentCheckConfig` with settings for max hops, probe count, interval, protocol, and packet size
- **ASN enrichment at collection time** — Hop IPs enriched via GeoLite2 MMDB (reusing existing `ip_geo_enrichment_cache` pattern) before results are pushed; complete dataset stored so no downstream enrichment needed
- **MPLS label extraction** — Parse RFC 4884 ICMP extension objects from Time Exceeded responses to extract MPLS label stacks per hop
- **Proto additions** — New `MtrHopResult` and `MtrTraceResult` messages in `monitoring.proto` with MPLS, ASN, and geo fields
- **Agent integration** — MTR checks managed in PushLoop alongside existing ICMP checks; on-demand via ControlStream (`mtr.run`)

### Data Layer / CNPG

- **TimescaleDB hypertable `mtr_traces`** — Time-series storage for trace-level metadata (target, hop count, reachability, protocol, agent/gateway IDs)
- **TimescaleDB hypertable `mtr_hops`** — Per-hop time-series with latency stats, loss, jitter, MPLS labels, ASN, hostname; foreign-keyed to trace
- **Apache AGE integration** — MTR paths projected into `platform_graph` as `MTR_PATH` edges between Device/HopNode vertices, enabling God View overlay and path-change detection

### Web UI / Phoenix LiveView

- **MTR results LiveView page** — Hop-by-hop table with latency/loss sparklines, ASN column, MPLS labels, DNS hostnames
- **God View MTR overlay** — New topology layer showing MTR-discovered paths as animated directional edges with latency/loss heat coloring
- **Device detail MTR tab** — MTR traces to/from a specific device, historical path comparison
- **On-demand MTR trigger** — UI action to run ad-hoc MTR from any agent to any target

## Impact

- Affected specs: NEW `mtr-diagnostics` capability spec
- Affected specs (modified): `agent-configuration` (new check type), `age-graph` (new MTR_PATH edge type), `build-web-ui` (new MTR views)
- Affected code:
  - `go/pkg/mtr/` — New package (tracer, probes, statistics, DNS, MPLS, ASN enrichment)
  - `go/pkg/agent/push_loop.go` — MTR check scheduling and result collection
  - `go/pkg/agent/control_stream.go` — On-demand MTR command handler
  - `proto/monitoring.proto` — New message types
  - `elixir/serviceradar_core/` — MTR data ingestion, AGE graph projection, hypertable migrations
  - `elixir/web-ng/` — MTR LiveView pages, God View overlay, device detail tab

## Risks

- **Privilege requirements**: Raw sockets need CAP_NET_RAW or root. Mitigated by: (1) agent already requires this for ICMP scanner, (2) SOCK_DGRAM fallback on Linux
- **Resource consumption**: Continuous MTR probing generates more traffic than simple pings. Mitigated by: configurable intervals, probe counts, and max concurrent traces
- **Platform differences**: Raw socket behavior varies across Linux/macOS/BSD. Mitigated by: build tags and platform-specific socket handling (same pattern as existing `scan/` package)
- **MPLS visibility**: Not all routers include RFC 4884 extensions in ICMP responses. Mitigated by: MPLS fields are optional in results; absent labels simply omitted
- **MMDB file availability**: ASN enrichment requires GeoLite2-ASN.mmdb on the agent host. Mitigated by: graceful degradation — ASN fields left empty when MMDB unavailable
