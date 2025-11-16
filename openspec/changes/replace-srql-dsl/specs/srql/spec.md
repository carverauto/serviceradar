## ADDED Requirements

### Requirement: Rust SRQL service executes CNPG queries via Diesel
ServiceRadar MUST expose a Rust-based SRQL service that accepts the existing `/api/query` contract, uses Diesel.rs to translate DSL ASTs into SQL, and executes them against the CNPG clusters that now store device and telemetry data.

#### Scenario: Diesel-backed translator hits CNPG
- **GIVEN** the SRQL service running from `rust/bin/srql` (or the matching Docker image)
- **WHEN** it receives an authenticated `/api/query` request that filters devices by `site_id` and aggregates packet loss
- **THEN** the service converts the DSL into Diesel query builders that target the CNPG pool configured via `DATABASE_URL`, executes the resulting SQL, and returns JSON rows without delegating to Proton/OCaml components.

#### Scenario: Connection management respects SPIFFE/Kong policies
- **GIVEN** Kong forwards a client request with mutual TLS headers and SPIFFE identities issued by SPIRE
- **WHEN** the Rust SRQL service opens or reuses a CNPG connection
- **THEN** it uses the configured SPIFFE-aware credentials/cert bundles, logs connection failures, and enforces the existing request auth checks before issuing SQL.

### Requirement: SRQL DSL maps to CNPG schemas with backward compatibility
The new DSL MUST document and implement operators for selecting inventory, aggregations, and time-bucket queries against CNPG schemas while preserving behavior expected by dashboards that were built on top of the OCaml SRQL layer.

#### Scenario: Canonical dashboards run unchanged
- **GIVEN** a set of stored SRQL queries used by device search, alert pages, and demo dashboards
- **WHEN** the same SRQL statements are executed against the Rust service in CNPG mode
- **THEN** they succeed without syntax changes, leverage Diesel to emit SQL against `devices`, `telemetry_samples`, and other CNPG tables, and return the same columns (device id, timestamp, metric buckets) the UI expects.

#### Scenario: Unsupported Proton constructs fail fast
- **GIVEN** a user submits a query that references Proton-only stream operators (e.g., `STREAM WINDOW` or `FORMAT JSONEachRow`)
- **WHEN** the Rust SRQL parser encounters those constructs
- **THEN** it returns a descriptive error that the DSL is CNPG-backed and does not attempt to issue a Proton request.

### Requirement: Migration controls and observability protect the cut-over
We MUST be able to run the Rust and OCaml SRQL services side-by-side, compare results, and expose telemetry that shows query success/latency so operators can flip traffic to the new DSL without risking outages.

#### Scenario: Dual-run flag compares results
- **GIVEN** the `SRQL_RUST_DUAL_RUN=true` configuration on the core/service
- **WHEN** a query is processed
- **THEN** the system executes it against both the Rust/CNPG backend and the existing OCaml service, logs the row/latency deltas, and emits metrics so engineers can decide when parity has been reached.

#### Scenario: Rollout toggles and alerts
- **GIVEN** a deploy wants to disable the OCaml translator entirely
- **WHEN** the operator flips the corresponding feature flag or Kong route to point exclusively at the Rust service
- **THEN** health metrics (p95 latency, error counts) remain available in Prometheus/OTEL, alerts trigger if thresholds are exceeded, and rollback instructions are documented to re-enable the OCaml service if needed.
