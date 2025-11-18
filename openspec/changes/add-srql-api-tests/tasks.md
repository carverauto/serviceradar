## 1. SRQL API fixture harness
- [ ] 1.1 Define the fixture dataset (schema + seed rows) for devices and telemetry tables, and script loading it into the Postgres/CNPG instance the tests will hit.
- [ ] 1.2 Add a reusable Rust test helper that boots the SRQL service (HTTP + Diesel pool) against the fixture DB and exposes a function for issuing `/api/query` requests with headers.

## 2. DSL coverage tests
- [ ] 2.1 Implement integration tests that submit canonical DSL statements (filters, aggregations, ordering, pagination) and assert the JSON responses and metadata match golden fixtures.
- [ ] 2.2 Add regression tests for invalid DSL/fields plus malformed payloads to ensure the service returns 400 responses with descriptive error bodies instead of panics.
- [ ] 2.3 Cover auth + tenant scoping by testing requests that omit/alter the Kong API key (or SPIFFE headers) and asserting a 401 is returned.
- [ ] 2.4 Mirror the SRQL language reference examples (e.g., `in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true/false`) as translator-level unit tests so key:value semantics stay validated without spinning up the HTTP harness.

## 3. CI + docs updates
- [ ] 3.1 Wire the new SRQL API tests into `cargo test` / Bazel / CI workflows so PRs cannot merge without passing them.
- [ ] 3.2 Update contributor docs (e.g., `docs/docs/agents.md` or README) with steps for running the SRQL tests locally, including prerequisites for the fixture database.
