# Change: Add dashboard SRQL service views

## Why
The bundled Service Availability NOC dashboard originally declared frames for `in:service_availability`, `in:monitored_services`, and `in:slo_evaluations`, but those entities are not currently accepted by the SRQL backend. The short-term fix changed the dashboard to use only `in:services`; this keeps the default dashboard from failing, but it loses the richer dashboard contract we actually want.

ServiceRadar should make those dashboard-facing entities real SRQL entities backed by stable SQL/query planner support, so first-party and authored dashboards can query availability, monitored service inventory, and SLO pressure without hand-maintained LiveView-only transforms.

## What Changes
- Add SRQL parser/planner support for dashboard service entities:
  - `in:service_availability`
  - `in:monitored_services`
  - `in:slo_evaluations`
- Define stable field contracts, supported filters, sorting, limits, and time-window behavior for those entities.
- Back the entities with existing service status and availability data where possible, adding platform-schema views or migrations only where a stable read model is needed.
- Restore the Service Availability NOC dashboard frames to use the richer SRQL entities after backend tests prove the entities execute.
- Extend the SRQL catalog/builder metadata so dashboard authoring and package frames expose the new entities and fields.
- Add Rust SRQL tests and focused web-ng/dashboard package tests that would have caught unsupported dashboard frame entities before review.

## Impact
- Affected specs: `srql`
- Affected code:
  - `rust/srql/src/parser.rs`
  - `rust/srql/src/query/**`
  - `rust/srql/src/schema.rs`
  - `rust/srql/src/models.rs`
  - `elixir/serviceradar_core/priv/repo/migrations/**` if read-model views/tables are needed
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `elixir/web-ng/priv/dashboard-packages/service-availability-noc/**`
  - `elixir/web-ng/assets/js/dashboards/service_availability_noc.js`
