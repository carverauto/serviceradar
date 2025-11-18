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
- **GIVEN** a unit test that mirrors the SRQL example `in:activity time:last_24h stats:"count() as total_flows by connection.src_endpoint_ip" sort:total_flows:desc having:"total_flows>100" limit:20` (`docs/docs/srql-language-reference.md:82-84`)
- **WHEN** the translator parses and plans the DSL
- **THEN** the test asserts that grouped columns, aliases, and sort order match the documented semantics so future parser refactors cannot silently change field mapping or alias propagation.
