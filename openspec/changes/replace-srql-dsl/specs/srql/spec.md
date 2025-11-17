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

### Requirement: Rust SRQL service is the sole `/api/query` backend
The OCaml translator MUST be fully removed once the Rust implementation lands so every environment routes `/api/query` traffic exclusively to the CNPG-backed Rust service without any dual-run or Proton bridge modes.

#### Scenario: Kong routes only to the Rust translator
- **GIVEN** the demo or prod Kong gateway forwarding `/api/query` calls
- **WHEN** clients submit SRQL statements
- **THEN** the request terminates on the `rust/srql` deployment (or its Docker Compose equivalent), there is no live OCaml SRQL pod to consult, and the response is produced solely by the CNPG-backed Diesel planner.

#### Scenario: Legacy dual-run toggles are gone
- **GIVEN** operators rolling out new SRQL code or adjusting configs
- **WHEN** they inspect environment variables, Helm values, or Docker Compose overrides
- **THEN** there are no `SRQL_DUAL_*` flags or Proton passthrough settings to enable the OCaml translator; the only configurable backend is the Rust service’s CNPG connection.
