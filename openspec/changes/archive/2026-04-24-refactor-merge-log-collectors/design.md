## Context
ServiceRadar runs two Rust log-collection daemons — Flowgger and OTEL — that evolved independently but converged on the same output target (NATS JetStream `events` stream) and share deployment patterns (mTLS, SPIFFE, config-bootstrap). Merging them reduces operational complexity and gives operators a single binary and config surface for all log inputs.

## Goals / Non-Goals
- **Goals**:
  - Single binary (`serviceradar-log-collector`) handling syslog, GELF, and OTEL gRPC inputs
  - Single TOML config with per-input enable/disable (config delegation to native configs)
  - Health check gRPC service covering all inputs (tonic-health on port 50044)
  - Backward-compatible NATS subjects (`logs.syslog`, `logs.otel`, `otel.traces`, `otel.metrics`)
  - Feature flags in Cargo.toml so inputs can be compiled out (e.g., `--features syslog,otel`)
  - Minimal divergence from upstream Flowgger
- **Non-Goals**:
  - Changing the NATS subject schema or stream topology
  - Adding new input protocols (e.g., Kafka input, HTTP/JSON)
  - Modifying the Elixir consumer side
  - Rewriting Flowgger's internal architecture
  - Unifying NATS output code (deferred — would diverge Flowgger from upstream)

## Decisions

### Approach: Compose Flowgger + OTEL under one binary
Rather than rewriting either collector, we compose them as library dependencies under a single binary. Each pipeline retains its own config format, NATS output, and internal architecture. The log-collector is a thin composition and orchestration layer.

### Crate structure
- `rust/log-collector/` — new crate (Rust 2024), the unified entrypoint
- `rust/flowgger/` — library-only crate (`serviceradar-flowgger`), internal modules preserved as-is
- `rust/otel/` — library-only crate, keeps proto compilation, gRPC handlers, NATS output self-contained
- Cargo features: `syslog` (Flowgger pipeline), `otel` (OTEL gRPC input), both default on

### Config delegation
The unified config does NOT rewrite either crate's config format. Instead it delegates:

```toml
[flowgger]
enabled = true
config_file = "/etc/serviceradar/flowgger.toml"

[otel]
enabled = true
config_file = "/etc/serviceradar/otel.toml"

[health]
listen_addr = "0.0.0.0:50044"
```

Each sub-collector reads its own native TOML config. This avoids any config format migration and lets existing configs work as-is.

### Flowgger integration
- Flowgger's `start(config_file)` function is called from `tokio::task::spawn_blocking` in the log-collector main
- Flowgger runs its own sync thread pool as it always has — no async rewrite needed
- Flowgger's built-in gRPC health server (`grpc::maybe_spawn`) is disabled when running under log-collector (by omitting the `[grpc]` section from the delegated flowgger config)
- All input/decoder/encoder/splitter/merger/output modules stay untouched

### OTEL integration
- OTEL's library API (`create_collector`, `start_server`, `start_metrics_server`) is called from the log-collector's async main
- OTEL's own NATS output and gRPC TLS setup are preserved as-is
- Config is loaded via config-bootstrap, same as the standalone binary

### Health check
- The log-collector runs a single tonic-health gRPC server on port 50044
- Reports `ServingStatus::Serving` for services: `""`, `"log-collector"`, `"flowgger"` (if enabled), `"otel"` (if enabled)
- Replaces both Flowgger's built-in health server and OTEL's HTTP `/health` endpoint as the K8s probe target
- K8s probes use `grpc:50044` instead of `tcpSocket:4317`

### NATS output (deferred unification)
Both crates retain their own NATS output implementations:
- Flowgger: sync worker threads with embedded Tokio runtimes, single subject (`logs.syslog`)
- OTEL: async `async_nats`, multiple subjects (`otel.traces`, `otel.metrics`, `logs.otel`, `otel.metrics.raw`)

Unifying these would require modifying Flowgger's output layer, creating the main divergence point from upstream. Since both outputs work correctly and independently, this is deferred to a future iteration if the maintenance burden warrants it.

## Risks / Trade-offs
- **Flowgger thread model mismatch** — Flowgger uses sync mpsc channels + thread pools; OTEL is fully async Tokio. Mitigation: Flowgger runs its own thread pool via `spawn_blocking`. The two runtimes coexist without rewriting Flowgger internals.
- **Feature bloat** — single binary is larger. Mitigation: Cargo feature flags allow stripping unused inputs.
- **Breaking deployment configs** — existing Helm values, docker-compose, systemd references change. Mitigation: all configs and references updated in this change.
- **Cert name changes** — `flowgger.pem`/`otel.pem` → `log-collector.pem`. Mitigation: all cert generation scripts updated.

## Open Questions (resolved)
- **Keep Flowgger's Redis and Kafka input support?** Yes — they come along for free since Flowgger is preserved as-is.
- **GELF compile-time feature or always included?** Always included — ships with the `syslog` feature.
- **Unify NATS output?** Deferred — preserving upstream compatibility is higher priority.
