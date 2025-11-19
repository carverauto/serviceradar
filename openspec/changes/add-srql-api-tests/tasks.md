## 1. SRQL API fixture harness
- [x] 1.1 Define the fixture dataset (schema + seed rows) for devices and telemetry tables, and script loading it into the Postgres/CNPG instance the tests will hit.
- [x] 1.2 Add a reusable Rust test helper that boots the SRQL service (HTTP + Diesel pool) against the fixture DB and exposes a function for issuing `/api/query` requests with headers.

## 2. DSL coverage tests
- [x] 2.1 Implement integration tests that submit canonical DSL statements (filters, aggregations, ordering, pagination) and assert the JSON responses and metadata match golden fixtures.
- [x] 2.2 Add regression tests for invalid DSL/fields plus malformed payloads to ensure the service returns 400 responses with descriptive error bodies instead of panics.
- [x] 2.3 Cover auth + tenant scoping by testing requests that omit/alter the Kong API key (or SPIFFE headers) and asserting a 401 is returned.
- [x] 2.4 Mirror the SRQL language reference examples (e.g., `in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true/false`) as translator-level unit tests so key:value semantics stay validated without spinning up the HTTP harness. *(Added doc-driven unit tests under `rust/srql/src/query/mod.rs`, plus module-level stats tests for `devices`, `interfaces`, `pollers`, `logs`, and `cpu_metrics` so documented flows stay hermetic.)*

## 3. CI + docs updates
- [ ] 3.1 Wire the new SRQL API tests into `cargo test` / Bazel / CI workflows so PRs cannot merge without passing them. *(GitHub `tests-rust.yml` now runs on ARC-hosted runners and installs GCC/Clang + `protoc` via whatever package manager is present (apt/dnf/yum/microdnf) so SRQL + other Rust crates link successfully in both Ubuntu and Oracle Linux images.)*
- [ ] 3.2 Update contributor docs (e.g., `docs/docs/agents.md` or README) with steps for running the SRQL tests locally, including prerequisites for the fixture database.
