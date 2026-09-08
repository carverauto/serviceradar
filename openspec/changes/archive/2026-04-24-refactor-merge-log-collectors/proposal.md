# Change: Merge OTEL and Flowgger into unified serviceradar-log-collector

## Why
ServiceRadar currently ships two independent Rust daemons for log ingestion — Flowgger (syslog/GELF via UDP/TCP/TLS) and the OTEL collector (OpenTelemetry gRPC). Both publish to the same NATS JetStream `events` stream, share identical TLS/mTLS bootstrapping, and duplicate NATS output logic. Maintaining two binaries doubles the build, packaging, deployment, and operational surface for what is fundamentally one concern: receiving logs and forwarding them to NATS.

## What Changes
- **New crate** `rust/log-collector/` — single binary `serviceradar-log-collector` replacing both standalone daemons
- **Flowgger preserved as library** — `rust/flowgger/` stays in the workspace as a library-only crate, keeping its input/decoder/encoder/splitter/merger modules intact for upstream compatibility
- **OTEL preserved as library crate** — `rust/otel/` stays in the workspace as a library-only crate, keeping proto compilation and gRPC handlers self-contained
- **Config delegation** — unified TOML config with `[flowgger]` and `[otel]` sections pointing to their native config files, plus `[health]` for the unified gRPC health server
- **Unified gRPC health** — single tonic-health server on port 50044 reporting status for all enabled pipelines
- **Single Dockerfile, Helm template, systemd unit, and entrypoint** replacing the two per-service variants
- **Converted** both `rust/flowgger/` and `rust/otel/` from standalone binaries to library-only crates (removed `[[bin]]` targets and `main.rs`)
- **BREAKING**: container image changes from `serviceradar-flowgger` + `serviceradar-otel` to `serviceradar-log-collector`
- **BREAKING**: systemd service changes from `serviceradar-flowgger` + `serviceradar-otel` to `serviceradar-log-collector`
- **BREAKING**: Helm values move from `flowgger.*` + `otel.*` to `logCollector.*`
- **BREAKING**: cert names change from `flowgger.pem`/`otel.pem` to `log-collector.pem`

## Impact
- Affected specs: `observability-signals` (log ingestion layer), `docker-compose-stack`, `edge-architecture`
- Affected code:
  - `rust/flowgger/` — converted to library-only (no standalone binary)
  - `rust/otel/` — converted to library-only (no standalone binary)
  - `rust/log-collector/` — new unified crate (binary + config)
  - `docker/compose/Dockerfile.flowgger`, `Dockerfile.otel` — removed, replaced by `Dockerfile.log-collector`
  - `docker/compose/entrypoint-flowgger.sh`, `entrypoint-otel.sh` — removed, replaced by `entrypoint-log-collector.sh`
  - `docker/compose/flowgger.docker.toml`, `otel.docker.toml` — retained as sub-collector configs (cert paths updated)
  - `docker/compose/log-collector.docker.toml` — new unified config pointing to sub-collector configs
  - `build/packaging/flowgger/`, `build/packaging/otel/` — removed, replaced by `build/packaging/log-collector/`
  - `helm/serviceradar/templates/flowgger.yaml`, `otel.yaml` — removed, replaced by `log-collector.yaml`
  - `k8s/demo/base/serviceradar-flowgger.yaml`, `serviceradar-otel.yaml` — removed
  - `docker-compose.yml` — old `flowgger` + `otel` services removed, new `log-collector` service added
  - All cert generation scripts, SPIRE configs, service aliases updated
  - CI workflows and build scripts updated

## Deferred
- **NATS output unification** (Section 2) — both crates retain their own NATS output implementations. Unifying would require diverging Flowgger from upstream, which conflicts with the goal of preserving upstream compatibility.
- **Unified Prometheus metrics** (3.4) — each pipeline retains its own metrics. A unified `/metrics` endpoint is a future enhancement.
- **External NATS publisher injection** (3.2) — depends on NATS unification.
