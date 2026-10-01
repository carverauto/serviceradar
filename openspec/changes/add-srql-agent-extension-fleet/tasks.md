## 1. Implementation

- [x] 1.1 Compile validated native add-on and WASM plugin fleet read plans.
- [x] 1.2 Execute plans through scoped Ash resources, preserving partition identity and safe projections.
- [x] 1.3 Wire RBAC, Arrow responses, visualization metadata, and catalog aliases.
- [x] 1.4 Document operator queries and freshness/drift semantics.
- [x] 1.5 Add healthy, stale, unhealthy, unassigned, version drift, plugin runtime, and authorization coverage.

## 2. Validation

- [x] 2.1 Pass focused Rust and web-ng unit tests, including negative controls for placeholders and catalog filters.
- [x] 2.2 Pass remote formatting/Credo, strict SRQL Clippy, and OpenSpec validation.
- [x] 2.3 Pass the repository-wide `make test` sweep (371 passing targets; two Swift targets skipped).

The persisted fleet query scenarios are registered in the shared fixture DB lane.
They have not been run locally; that lane must execute them before shipment.
