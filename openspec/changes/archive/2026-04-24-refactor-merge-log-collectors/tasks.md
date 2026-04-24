## 1. Crate scaffolding
- [x] 1.1 Create `rust/log-collector/` crate with Cargo.toml, feature flags (`syslog`, `otel`), depend on `serviceradar-flowgger` as library
- [x] 1.2 Add `log-collector` to workspace `Cargo.toml` members
- [x] 1.3 Set up module structure: `main.rs`, `config.rs`
- [x] 1.4 Flowgger already exposes `start()` as library entry point — no changes needed

## 2. NATS output unification (DEFERRED)
Deferred to preserve Flowgger upstream compatibility. Both crates retain their own NATS output implementations.
- [ ] 2.1 Extract shared JetStream client setup, stream ensure/update logic from both `nats_output.rs` files into `log-collector/src/nats_output.rs`
- [ ] 2.2 Implement unified `NatsPublisher` with per-subject publish and retry
- [ ] 2.3 Port TLS and credential loading from existing implementations
- [ ] 2.4 Wire Flowgger to use unified `NatsPublisher` in place of its own `nats_output.rs`
- [ ] 2.5 Add unit tests for publisher setup and stream management

## 3. OTEL library crate
- [x] 3.1 OTEL already exposes library entry points (`create_collector`, `start_server`, etc.) — no changes needed
- [ ] 3.2 Wire `ServiceRadarCollector` to accept an external NATS publisher (DEFERRED — depends on Section 2)
- [x] 3.3 Wire OTEL dependency behind `otel` feature flag in log-collector
- [ ] 3.4 Port Prometheus metrics endpoint into unified metrics module (DEFERRED)

## 4. Unified config and server
- [x] 4.1 Implement unified TOML config parser with `[flowgger]` and `[otel]` sections pointing to native config files
- [x] 4.2 Port config-bootstrap integration
- [x] 4.3 Implement main entrypoint: spawn Flowgger pipeline (via `spawn_blocking`) + OTEL gRPC server (async) based on config
- [x] 4.4 Unified gRPC health check service covering both pipelines (`[health]` config section, tonic-health on port 50044)
- [x] 4.5 Port CLI argument parsing

## 5. Deployment artifacts
- [x] 5.1 Create `docker/compose/Dockerfile.log-collector`
- [x] 5.2 Create `docker/compose/entrypoint-log-collector.sh`
- [x] 5.3 Create `docker/compose/log-collector.docker.toml`
- [x] 5.4 Create `build/packaging/log-collector/systemd/serviceradar-log-collector.service`
- [x] 5.5 Create `build/packaging/log-collector/config/log-collector.toml`
- [x] 5.6 Create `helm/serviceradar/templates/log-collector.yaml`
- [x] 5.7 Update `docker-compose.yml` — add `log-collector` service, mark `flowgger`/`otel` as legacy profiles

## 6. Integration testing (docker-compose)
- [x] 6.1 Verify syslog UDP input → NATS `logs.syslog` subject (RFC 3164 → GELF JSON, verified from inside Docker network)
- [x] 6.2 Verify OTEL gRPC input → NATS `otel.traces`, `otel.metrics`, `otel.metrics.raw`, `logs.otel` subjects (all three gRPC services verified via grpcurl)
- [x] 6.3 Verify health check gRPC endpoint (all 4 services: `""`, `"log-collector"`, `"flowgger"`, `"otel"` return SERVING)
- [x] 6.4 Verify mTLS credential loading (both pipelines connect to NATS with mTLS using `log-collector.pem` certs; OTEL gRPC TLS enabled)

## 7. Cleanup
- [x] 7.1 Convert `rust/otel/` from binary to library-only crate (removed `[[bin]]` and `main.rs`)
- [x] 7.2 Convert `rust/flowgger/` from binary to library-only crate (removed `[[bin]]` and `main.rs`)
- [x] 7.3 Remove old Dockerfiles (`Dockerfile.otel`, `Dockerfile.flowgger`) and entrypoints
- [x] 7.4 Remove old entrypoints, configs, systemd units for otel (`build/packaging/otel/`)
- [x] 7.5 Remove old Helm templates (`otel.yaml`, `flowgger.yaml`) and update SPIRE IDs
- [x] 7.6 Remove old docker-compose services (`flowgger`, `otel`) and volumes
- [x] 7.7 Update Helm `values.yaml` — replace `flowgger.*` / `otel.*` with `logCollector.*`, update SPIRE SAs, configSync, cert generation, otelExporter endpoint
- [x] 7.8 Update CI workflows (`tests-rust.yml`, `sbom-images.yml`) and `scripts/build-images.sh`
