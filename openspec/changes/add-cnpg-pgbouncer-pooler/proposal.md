# Change: Add CNPG PgBouncer pooler support

## Why
Recent demo and Docker investigations exposed connection-pressure failure modes where application pools, background jobs, and operator-facing requests can exhaust or stall direct Postgres backends. Kubernetes deployments already run through CNPG, so ServiceRadar should use CNPG's native PgBouncer `Pooler` resource to add an explicit connection-pooling layer for supported application traffic instead of relying only on per-service pool tuning.

## What Changes
- Add Helm values and templates for CNPG-managed PgBouncer poolers, starting with an RW transaction pooler for application query traffic.
- Route PgBouncer-safe ServiceRadar database clients through the pooler while keeping migrations, bootstrap, admin, and session-sensitive database paths on the direct CNPG RW service.
- Update demo values so the `demo` namespace runs the pooler by default and validates the production Kubernetes path.
- Add runtime configuration needed for PgBouncer transaction pooling, including unnamed prepared statements or equivalent client settings where required.
- Add observability and readiness checks for pooler deployment health, pool saturation, and fallback/direct-connection behavior.

## Impact
- Affected specs:
  - `cnpg`
- Affected code:
  - `helm/serviceradar/values.yaml`
  - `helm/serviceradar/values-demo.yaml`
  - new Helm template(s) for `postgresql.cnpg.io/v1` `Pooler`
  - Helm templates that inject `CNPG_HOST`, `CNPG_PORT`, and database client runtime settings
  - `elixir/serviceradar_core/config/runtime.exs`
  - `elixir/serviceradar_core_elx/config/runtime.exs`
  - `elixir/web-ng/config/runtime.exs`
  - Go/Rust database client config paths if any Kubernetes workload is routed through the pooler
  - docs for Helm configuration, CNPG monitoring, and demo rollout

## Relationship To Existing Work
This complements `refactor-control-plane-db-workload-isolation` rather than replacing it. PgBouncer smooths and caps Postgres backend connections at the deployment boundary; workload isolation still reserves application-side capacity and prevents background work from overwhelming critical paths before traffic reaches Postgres.
