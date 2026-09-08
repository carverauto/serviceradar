## Context

The project currently has two separate Rust crates — `rust/sflow-collector/` and `rust/netflow-collector/` — that perform the same fundamental job: receive UDP flow datagrams, parse them into `FlowMessage` protobufs, and publish to NATS JetStream. They share identical publisher, config scaffolding, metrics, error, security, and orchestration code. The converters and parsers differ by protocol but produce the same output type. Both crates depend on `proto/flow/flow.proto` which already defines a unified `FlowMessage` with a `FlowType` enum covering `SFLOW_5`, `NETFLOW_V5`, `NETFLOW_V9`, and `IPFIX`.

## Goals / Non-Goals

**Goals:**
- Single `flow-collector` binary that accepts multiple UDP listeners, each bound to a protocol type
- Eliminate all duplicated code (publisher, config scaffolding, security, metrics, main.rs)
- Preserve all existing protocol-specific behavior (sFlow sample conversion, NetFlow template caching, pending flows, etc.)
- Share one NATS connection and publisher across all listeners
- Per-listener configuration for port, buffer size, and protocol-specific options
- Single Docker image replacing two

**Non-Goals:**
- Adding new protocol support (e.g., NetFlow v1, sFlow v2/v4) — only what exists today
- Changing the `FlowMessage` protobuf schema
- Modifying NATS subject semantics or stream topology
- Adding a listener management API or hot-reloading of listener config
- Refactoring the converter logic itself (sFlow and NetFlow converters stay as-is, just relocated)

## Decisions

### 1. Config structure: top-level shared settings + `listeners` array

**Decision**: Split config into shared fields (NATS, security, buffering) at the top level and a `listeners` array where each entry specifies a protocol and its protocol-specific options.

**Alternatives considered**:
- *Flat config with protocol-specific field prefixes* (`sflow_listen_addr`, `netflow_listen_addr`) — doesn't scale, messy validation
- *Separate config files merged at startup* — adds operational complexity, no clear benefit

**Rationale**: A `listeners` array naturally models N independent UDP endpoints. Serde's internally-tagged enum (`#[serde(tag = "protocol")]`) cleanly separates protocol-specific options while keeping the JSON ergonomic.

```json
{
  "nats_url": "nats://localhost:4222",
  "stream_name": "events",
  "security": { "mode": "none" },
  "channel_size": 10000,
  "batch_size": 100,
  "listeners": [
    {
      "protocol": "sflow",
      "listen_addr": "0.0.0.0:6343",
      "subject": "flows.raw.sflow",
      "max_samples_per_datagram": 1000
    },
    {
      "protocol": "netflow",
      "listen_addr": "0.0.0.0:2055",
      "subject": "flows.raw.netflow",
      "pending_flows": { "max_pending_flows": 256 }
    }
  ]
}
```

### 2. Module layout: protocol submodules under `src/`

**Decision**: Organize protocol-specific code into submodules, shared code at the crate root.

```
rust/flow-collector/src/
├── main.rs
├── config.rs          # Unified config with ListenerConfig enum
├── publisher.rs       # Single shared publisher (from either existing impl — they're identical)
├── metrics.rs         # Unified metrics with per-listener labels
├── error.rs           # Combined error types
├── listener.rs        # Generic listener loop that delegates to protocol handler
├── sflow/
│   ├── mod.rs         # SflowHandler implementing FlowHandler trait
│   └── converter.rs   # Existing sflow converter, relocated
└── netflow/
    ├── mod.rs         # NetflowHandler implementing FlowHandler trait
    └── converter.rs   # Existing netflow converter, relocated
```

**Alternatives considered**:
- *Workspace library crate with shared code* — over-engineered for two protocols in one binary
- *Keep converters at root level* (`sflow_converter.rs`, `netflow_converter.rs`) — submodules group related code better and match the tagged config enum

### 3. Protocol abstraction: `FlowHandler` trait

**Decision**: Define a minimal trait that each protocol implements:

```rust
trait FlowHandler: Send + Sync {
    /// Parse a raw UDP datagram and return zero or more FlowMessages.
    fn parse_datagram(&self, buf: &[u8], len: usize, peer: std::net::SocketAddr) -> Vec<FlowMessage>;

    /// Return the protocol name for logging/metrics.
    fn protocol_name(&self) -> &'static str;
}
```

The generic listener loop calls `handler.parse_datagram()` and sends results through the shared mpsc channel. Each protocol's handler owns its parser state (sFlow's `SflowParser`, NetFlow's `AutoScopedParser` behind a Mutex).

**Alternatives considered**:
- *Enum dispatch instead of trait* — works but couples the listener loop to every protocol variant; trait is more extensible
- *No abstraction, just two separate listener functions* — duplicates the UDP recv loop, defeats the purpose

**Rationale**: The trait boundary is narrow (one method that matters), so there's minimal abstraction overhead. It cleanly separates "receive UDP and send to channel" from "parse protocol X".

### 4. Shared publisher with merged subjects

**Decision**: One `Publisher` instance receives from one `mpsc::Receiver`. All listeners share the sender half. The publisher's NATS stream is configured with subjects from all listeners (merged and deduplicated via `stream_subjects_resolved()`).

**Alternatives considered**:
- *Per-listener publisher* — wastes NATS connections, complicates stream subject management
- *Per-listener channel, single publisher with select!* — unnecessary complexity; tokio mpsc is multi-producer by design

**Rationale**: The existing publisher is already designed for a single channel. Multiple `mpsc::Sender` clones feeding one receiver is idiomatic tokio.

### 5. Per-listener metrics with protocol label

**Decision**: Each listener tracks its own `AtomicU64` counters (packets_received, flows_converted, flows_dropped, parse_errors). The metrics reporter iterates all listeners and logs with a protocol/address label prefix.

**Alternatives considered**:
- *Global aggregated metrics only* — loses per-listener visibility
- *Prometheus metrics with labels* — good future direction but out of scope; current approach is log-based

### 6. Listener failure isolation

**Decision**: Each listener runs as an independent `tokio::spawn` task. If one listener panics or errors, the others continue. The main `tokio::select!` monitors all listener handles plus the publisher handle; if the publisher dies, the process exits (all listeners become useless without a publisher).

## Risks / Trade-offs

- **Migration burden** → Operators with existing deployments must rewrite configs and switch container images. Mitigation: provide example configs and document the migration in release notes.
- **Single process failure domain** → One binary means a crash affects all protocols. Mitigation: listeners are task-isolated; only publisher/main failures are global. The previous separate-binary model had the same NATS single-point-of-failure anyway.
- **Larger binary size** → Both parser crates are compiled in. Mitigation: negligible (~1-2 MB combined); both are already small crates.
- **NetFlow parser Mutex contention** → The `AutoScopedParser` requires `Mutex` wrapping since it's not `Send+Sync`. Mitigation: each NetFlow listener gets its own parser instance (no sharing across listeners), so contention is only within a single listener's recv loop — same as today.
