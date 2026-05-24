## 1. SRQL Backend
- [x] 1.1 Add parser aliases/entities for `service_availability`, `monitored_services`, and `slo_evaluations`.
- [x] 1.2 Implement `service_availability` query planning/execution with supported filters, sorting, limits, and time-window behavior.
- [x] 1.3 Implement `monitored_services` query planning/execution as a stable latest-service inventory view.
- [x] 1.4 Implement initial derived `slo_evaluations` query planning/execution, including `rollup_stats:slo_error_budget`.
- [x] 1.5 Add or update platform-schema migrations if stable SQL views/read models are needed.
- [x] 1.6 Update SRQL schema/model metadata for any new read models.

## 2. Web-NG Integration
- [x] 2.1 Update SRQL catalog metadata so the new entities and fields are available to builder/search surfaces.
- [x] 2.2 Restore the Service Availability NOC package frame queries to `in:service_availability`, `in:monitored_services`, and `in:slo_evaluations`.
- [x] 2.3 Update the built-in Service Availability NOC renderer for the restored richer field contracts.
- [x] 2.4 Add package-frame validation so first-party required frames cannot target unsupported SRQL entities.

## 3. Tests
- [x] 3.1 Add Rust SRQL parser/planner tests for all new entities.
- [x] 3.2 Add Rust SQL generation and/or integration tests for service availability and monitored services.
- [x] 3.3 Add tests for derived SLO evaluation rows and `rollup_stats:slo_error_budget`.
- [x] 3.4 Add web-ng tests for dashboard package frame execution with the restored manifest.
- [x] 3.5 Run focused SRQL, web-ng, asset, and OpenSpec validations.
