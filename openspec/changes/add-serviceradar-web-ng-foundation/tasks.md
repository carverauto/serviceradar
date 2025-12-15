## 1. Implementation

### Phoenix App Scaffolding
- [ ] 1.1 Create the `web-ng/` directory and scaffold a new Phoenix LiveView app inside it (app `:serviceradar_web_ng`, module `ServiceRadarWebNG`) configured for Ecto + Postgres.
  - [ ] Run `mix phx.new web-ng --app serviceradar_web_ng --module ServiceRadarWebNG --live --no-mailer`
- [ ] 1.2 Configure esbuild + tailwind assets pipeline.
- [ ] 1.3 Configure Phoenix telemetry and LiveDashboard.

### Database Connectivity
- [ ] 1.4 Configure runtime database connectivity (CNPG/Timescale) with TLS support in `config/runtime.exs`.
  - [ ] Support `DATABASE_URL` parsing
  - [ ] Support CA bundle mount path via `SSL_CA_CERT_PATH` env var
  - [ ] Document required environment variables
- [ ] 1.5 Add read-only Ecto schemas for initial core tables/views (at minimum: `unified_devices`, `pollers`, `services`) using string primary keys where needed.

### Apache AGE Graph Integration
- [ ] 1.6 Port `guided/guided/lib/guided/graph.ex` into `ServiceRadarWebNG.Graph`:
  - [ ] Update `@graph_name` to `"serviceradar"`
  - [ ] Harden parameterization (use AGE's `cypher($graph, $query, $params)` form)
  - [ ] Update Repo alias and module references
- [ ] 1.7 Add `mix sr.graph.verify` task to validate AGE connectivity and graph availability (based on `guided/lib/mix/tasks/graph_setup.ex`).

### SRQL NIF Integration
- [ ] 1.8 Add NIF-friendly query execution API to `rust/srql`:
  - [ ] Add `pub async fn execute_query(pool, query_str) -> Result<QueryResult>` that bypasses HTTP server context
  - [ ] Add `pub fn translate(query_str) -> Result<TranslateResult>` for query validation/debugging
  - [ ] Ensure these functions are usable without starting the HTTP server
- [ ] 1.9 Add Rustler scaffolding (`web-ng/native/srql_nif`) and an Elixir wrapper module (`ServiceRadarWebNG.SRQL`).
- [ ] 1.10 Implement SRQL NIF with:
  - [ ] Panic containment (`catch_unwind` on all NIF entry points)
  - [ ] Async-safe execution (dirty schedulers or pid-message callback pattern)
  - [ ] Connection pool management (held in NIF resource)
- [ ] 1.11 Expose `ServiceRadarWebNG.SRQL.translate/1` and `ServiceRadarWebNG.SRQL.execute/2` functions.

### Minimal UI Validation
- [ ] 1.12 Add a minimal `/ng` LiveView area with:
  - [ ] DB connection status (simple Ecto query)
  - [ ] AGE graph smoke query via `ServiceRadarWebNG.Graph`
  - [ ] SRQL translate + execute round-trip via `ServiceRadarWebNG.SRQL`

### Deployment
- [ ] 1.13 Create `web-ng/Dockerfile` (multi-stage build: Elixir release + Rust/Rustler compilation).
- [ ] 1.14 Add Docker Compose support to run `serviceradar-web-ng` alongside existing services:
  - [ ] New `web-ng` service on port 4000
  - [ ] Update Nginx routing: `/ng/*` → Phoenix, `/` → Next.js (unchanged)
- [ ] 1.15 (Optional) Add K8s demo manifests for `serviceradar-web-ng` (Deployment/Service + Ingress routing rule).

## 2. Validation
- [ ] 2.1 Run `openspec validate add-serviceradar-web-ng-foundation --strict`.
- [ ] 2.2 Run `mix format`, `mix compile --warnings-as-errors`, and `mix test` for `serviceradar-web-ng`.
- [ ] 2.3 Run `cargo fmt --check`, `cargo clippy`, and `cargo test` for `rust/srql` changes.
- [ ] 2.4 Smoke test in Docker Compose:
  - [ ] Load `/ng` and verify page renders
  - [ ] Run a graph query via the UI
  - [ ] Run an SRQL query via the UI
  - [ ] Verify Next.js at `/` is unaffected

## 3. Documentation
- [ ] 3.1 Document how to run `serviceradar-web-ng` locally (with Docker Compose CNPG) and how it differs from the legacy UI/API.
- [ ] 3.2 Document required environment variables (`DATABASE_URL`, `SSL_CA_CERT_PATH`, `SECRET_KEY_BASE`, etc.).
- [ ] 3.3 Document the Graph abstraction contract and basic usage patterns (parameterization rules, transaction wrapper).
- [ ] 3.4 Document the SRQL NIF contract and failure modes (panic containment, timeouts, concurrency limits).
