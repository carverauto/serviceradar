## 1. Helm Pooler Resources
- [x] 1.1 Add `cnpg.pooler` values for enablement, pooler name, mode, instances, pool sizing, PgBouncer parameters, and service host selection.
- [x] 1.2 Add a Helm template for the CNPG `Pooler` CRD bound to the configured CNPG cluster.
- [x] 1.3 Ensure the template is gated so installs without the CNPG Pooler CRD do not fail unless pooler support is explicitly enabled.
- [x] 1.4 Add HA placement controls for multi-pod Pooler deployments.
- [x] 1.5 Add Helm rendering tests or snapshot coverage for disabled and enabled pooler configurations.

## 2. Application Routing
- [x] 2.1 Inventory each Kubernetes workload that connects to CNPG and classify it as PgBouncer transaction-safe, session-sensitive, or direct-only.
- [x] 2.2 Route transaction-safe workloads to the pooler service when enabled.
- [x] 2.3 Keep migrations, bootstrap, DDL, and admin/superuser workflows on the direct CNPG RW service.
- [x] 2.4 Configure Elixir/Postgrex clients routed through transaction pooling to avoid named prepared statements.
- [x] 2.5 Add equivalent PgBouncer-safe settings for any Go/Rust database clients routed through the pooler.

## 3. Demo Rollout
- [x] 3.1 Enable the pooler in `helm/serviceradar/values-demo.yaml` with conservative HA sizing.
- [ ] 3.2 Deploy the chart to the `demo` namespace and verify the Pooler, services, and ServiceRadar pods become healthy.
- [ ] 3.3 Validate login, analytics, logs, MTR diagnostics, agent status, and background jobs through the pooler-enabled demo deployment.
- [ ] 3.4 Confirm direct migration/bootstrap paths still work on clean install and upgrade.

## 4. Observability And Operations
- [x] 4.1 Add pooler health, saturation, and connection-budget documentation to CNPG monitoring docs.
- [x] 4.2 Add a Prometheus Operator `PodMonitor` option for PgBouncer exporter metrics.
- [x] 4.3 Add Helm configuration docs explaining when to use direct CNPG, transaction pooling, and any session-sensitive bypass.
- [x] 4.4 Add operational verification commands for `kubectl get pooler`, generated services, and PgBouncer pool stats.

## 5. Release Validation
- [x] 5.1 Run `helm template` for default and demo values.
- [x] 5.2 Run relevant Elixir quality/tests for changed runtime config.
- [x] 5.3 Run `openspec validate add-cnpg-pgbouncer-pooler --strict`.
