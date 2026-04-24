## 1. Shared OTEL Library (serviceradar_core)
- [x] 1.1 Add OTEL dependencies to `serviceradar_core/mix.exs`: `opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter`, `opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_oban`
- [x] 1.2 Create `ServiceRadar.Telemetry.OtelSetup` module that configures SDK, OTLP/gRPC exporter with mTLS, and resource attributes (service.name, service.version, deployment.environment)
- [x] 1.3 Add mTLS certificate loading helper that reads `OTEL_CERT_DIR` / `OTEL_CERT_NAME` env vars (reuse existing TLS cert patterns from datasvc/NATS config)
- [ ] 1.4 Bridge existing custom telemetry events (`[:serviceradar, :actors, :device]`, cluster health) to OTEL spans/metrics
- [ ] 1.5 Write unit tests for OtelSetup (SDK initialization, resource attribute population, cert path resolution)

## 2. core-elx Integration
- [x] 2.1 OTEL deps inherited from serviceradar_core (added `opentelemetry` to extra_applications)
- [x] 2.2 Call `OtelSetup.configure/1` in Application.start with `service.name: "serviceradar-core-elx"`
- [x] 2.3 Attach Oban telemetry handlers for job traces and metrics (via instrumentations: [:oban])
- [x] 2.4 Attach Ecto telemetry handlers for database query traces (via instrumentations: [:ecto])
- [x] 2.5 Add OTEL runtime config to `config/runtime.exs`
- [ ] 2.6 Verify traces, metrics, and logs export in dev environment

## 3. web-ng Integration
- [x] 3.1 OTEL deps inherited from serviceradar_core (added `opentelemetry` to extra_applications)
- [x] 3.2 Call `OtelSetup.configure/1` in Application.start with `service.name: "serviceradar-web-ng"`
- [x] 3.3 Attach Phoenix telemetry handlers for HTTP request traces (via instrumentations: [:phoenix])
- [x] 3.4 Attach Ecto telemetry handlers for database query traces (via instrumentations: [:ecto])
- [x] 3.5 Add OTEL runtime config to `config/runtime.exs`
- [ ] 3.6 Verify traces, metrics, and logs export in dev environment

## 4. agent-gateway Integration
- [x] 4.1 OTEL deps inherited from serviceradar_core (added `opentelemetry` to extra_applications)
- [x] 4.2 Call `OtelSetup.configure/1` in Application.start with `service.name: "serviceradar-agent-gateway"`
- [ ] 4.3 Add gRPC interceptor/middleware for incoming agent connections (trace context propagation)
- [x] 4.4 Add OTEL runtime config to `config/runtime.exs`
- [ ] 4.5 Verify traces, metrics, and logs export in dev environment

## 5. Docker Compose Configuration
- [x] 5.1 Add OTEL environment variables to core-elx service in `docker-compose.yml`
- [x] 5.2 Add OTEL environment variables to web-ng service in `docker-compose.yml`
- [x] 5.3 Add OTEL environment variables to agent-gateway service in `docker-compose.yml`
- [x] 5.4 Ensure Elixir services depend on `otel` service in docker-compose
- [ ] 5.5 Smoke test: start stack, generate traffic, verify OTEL subjects in NATS

## 6. Helm Chart Configuration
- [x] 6.1 Add OTEL env vars to core-elx deployment template
- [x] 6.2 Add OTEL env vars to web-ng deployment template
- [x] 6.3 Add OTEL env vars to agent-gateway deployment template
- [x] 6.4 Add configurable values to `values.yaml` (`otelExporter` section with endpoint, sampling ratio, enable/disable)
- [x] 6.5 Verified Helm template rendering with `helm template` (OTEL vars appear when enabled, absent when disabled)
- [ ] 6.6 Update `values-demo.yaml` if demo-specific overrides needed
