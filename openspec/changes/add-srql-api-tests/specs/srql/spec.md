## ADDED Requirements

### Requirement: SRQL `/api/query` tests cover canonical DSL flows
ServiceRadar MUST ship automated tests that exercise the SRQL DSL end-to-end by issuing `/api/query` requests against the Rust translator wired to a deterministic CNPG/Postgres fixture so regressions in parsing, planning, or serialization are caught before release.

#### Scenario: Canonical device filter succeeds
- **GIVEN** the SRQL test harness loads seeded `devices` + `telemetry_samples` rows into the fixture database
- **WHEN** the integration test submits the DSL statement used by the device inventory dashboard (filters by `site_id`, bucketizes packet loss, orders by `last_seen`)
- **THEN** the `/api/query` response matches the expected JSON rows and metadata stored with the test, proving the parser, planner, and Diesel executor cooperate correctly.

#### Scenario: Aggregation + pagination preserved
- **GIVEN** the same harness
- **WHEN** a test issues an aggregation query with `GROUP BY` buckets and a `LIMIT/OFFSET`
- **THEN** the translator returns consistent totals/page counts across runs so dashboards relying on those semantics cannot regress silently.

### Requirement: SRQL API fixtures are accessible from CI runners
The SRQL API suite MUST run in our Kubernetes-backed CI environment (BuildBuddy RBE + GitHub custom runners) without shelling out to a local Docker daemon. Tests use a shared CNPG fixture (TimescaleDB + Apache AGE) hosted in the cluster and receive a per-run database that is seeded/reset before executing.

#### Scenario: BuildBuddy Bazel runs leverage shared CNPG
- **GIVEN** the BuildBuddy executor exposes secrets/environment variables with the CNPG hostname, credentials, and target schema
- **WHEN** `bazel test //rust/srql:srql_api_test` runs remotely
- **THEN** the harness connects to the shared CNPG instance, re-seeds the fixture tables before each case, and finishes without needing Docker or outbound registry access.

#### Scenario: GitHub custom runners reuse the same fixture
- **GIVEN** our GitHub Actions workflow runs on the self-hosted runners in the cluster and mounts the same CNPG connection secrets
- **WHEN** `cargo test --test api` runs as part of CI
- **THEN** the suite connects to the shared fixture, resets the seed data, and produces deterministic results so CI is consistent regardless of runner location.

### Requirement: SRQL `/api/query` tests enforce error handling
The automated suite MUST also assert that invalid DSL or unauthorized requests trigger the documented 400/401 responses so error handling does not regress when evolving the translator.

#### Scenario: Invalid DSL returns 400
- **GIVEN** a test that submits an SRQL statement referencing an unsupported field/operator
- **WHEN** `/api/query` executes inside the harness
- **THEN** it returns HTTP 400 with a structured error body rather than panicking or falling through to a 500.

#### Scenario: Missing auth rejected with 401
- **GIVEN** the test helper omits the Kong API key/SPIFFE headers
- **WHEN** it posts to `/api/query`
- **THEN** the service responds with HTTP 401 and does not attempt to parse or execute the DSL payload.

### Requirement: SRQL DSL semantics validated by unit tests
Unit tests MUST exercise the SRQL language primitives documented in `docs/docs/srql-language-reference.md` so canonical `in:`, `time`, `sort`, `limit`, and boolean filter combinations keep returning deterministic result sets even if the HTTP harness is not running.

#### Scenario: Device availability filters stay aligned with docs
- **GIVEN** translator-level unit tests load fixture devices mirroring the documentation example (`docs/docs/srql-language-reference.md:92-95`)
- **WHEN** the tests execute `in:devices time:last_7d sort:last_seen:desc limit:20 is_available:true` and the companion `... is_available:false`
- **THEN** the translator plans both statements into the expected Diesel AST, and the assertions confirm the selected IDs / ordering / row counts, proving availability filters continue matching the DSL semantics.

#### Scenario: Aggregation example queries emit expected plans
- **GIVEN** translator-level unit tests that mirror the SRQL examples `in:devices discovery_sources:(sweep) discovery_sources:(armis) time:last_7d sort:last_seen:desc`, `in:services service_type:(ssh,sftp) timeFrame:"14 Days" sort:timestamp:desc`, and doc-driven stats queries (`docs/docs/srql-language-reference.md:93-104`)
- **WHEN** the translator parses and plans those DSL statements and the module-level stats helpers (devices, interfaces, pollers, cpu_metrics, logs) build SQL via `to_debug_sql`
- **THEN** the tests assert that filter semantics, order clauses, and stats SQL (e.g., `avg(usage_percent) as avg_cpu by device_id`) match the documented behavior so future parser refactors cannot silently change field mapping, alias propagation, or JSON payload structure.
