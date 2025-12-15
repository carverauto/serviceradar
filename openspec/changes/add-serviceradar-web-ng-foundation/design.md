# Design: `serviceradar-web-ng` foundation

## Goals
- Provide a Phoenix LiveView application that can run in parallel with the existing Next.js UI (`web/`) during the migration period.
- Avoid coupling the new application to the existing Core HTTP API and SRQL HTTP service; use the database as the primary integration surface.
- Reuse proven patterns from the reference `guided/` Phoenix app for Apache AGE (openCypher) interaction, while hardening parameterization and query ergonomics.
- Prepare an embedded SRQL execution path using Rustler + the existing Rust SRQL codebase (`rust/srql`), avoiding an HTTP hop.

## App location and naming
- **Directory (proposal):** `web-ng/` (the Phoenix app lives here in the ServiceRadar repo)
- **Mix app name:** `:serviceradar_web_ng`
- **OTP namespace:** `ServiceRadarWebNG`
- The existing `guided/` directory remains a reference/sample Phoenix app; `serviceradar-web-ng` MUST NOT depend on `guided` at runtime.

## Side-by-side routing and deployment
- **Development:** run `serviceradar-web` (Next.js) and `serviceradar-web-ng` (Phoenix) on separate ports; expose `serviceradar-web-ng` behind a path prefix (e.g. `/ng`) for convenience.
- **Docker Compose:** add an optional `web-ng` service listening on `:4000`; update Nginx routing so:
  - `/` continues to route to Next.js
  - `/ng/*` routes to Phoenix (`web-ng`)
- **Kubernetes:** add a second Deployment/Service and route prefix (or a separate host) without altering `serviceradar-core` or the existing SRQL service.

## Database integration (Ecto)
- Connect directly to CNPG/Timescale/AGE via `Ecto.Repo` using `DATABASE_URL` (and/or structured env vars).
- Support TLS verification against the CNPG CA bundle used by Compose/K8s (root cert path mounted into the container).
- Start **read-only**:
  - Define Ecto schemas mapping to existing tables/views (e.g. `unified_devices`, `pollers`, `services`) without generating migrations.
  - Use explicit primary keys for text IDs (as used today in Go) via `@primary_key {:id, :string, autogenerate: false}` where applicable.
- Schema ownership handover (Ecto migrations, `structure.sql`, disabling Go migrations) is explicitly out of scope for this change.

## Apache AGE graph abstraction (`ServiceRadarWebNG.Graph`)
Starting point: `guided/guided/lib/guided/graph.ex`.

Key updates for ServiceRadar usage:
- Graph name constant updates to `@graph_name "serviceradar"`.
- Provide a single entrypoint that ensures correct per-connection setup:
  - `LOAD 'age'`
  - `SET search_path = ag_catalog, "$user", public`
  - executed inside a `Repo.transaction/1` so the statements share a connection
- Prefer parameterized Cypher calls via `ag_catalog.cypher(graph, query, params_json)` when params are provided.
- Return results as parsed Elixir structures by converting `agtype` → JSON text and decoding.

Security note:
- Avoid interpolating user-controlled values into Cypher fragments (labels, properties, etc). Where dynamic labels are required, restrict them to a known allowlist and treat everything else as parameters.

## Embedded SRQL (Rustler NIF)
Goal: expose SRQL execution to Elixir without calling the existing SRQL HTTP service.

Approach:
- Add NIF-friendly public API to the existing `rust/srql` crate (it's already a library with `lib.rs`).
- Create a Rustler NIF crate under `web-ng/native/srql_nif` that depends on `rust/srql`.
- The NIF crate calls into `srql` library functions directly, bypassing the HTTP server.

### SRQL Library API Additions (`rust/srql/src/lib.rs`)
Add these public functions that don't require the HTTP server context:

```rust
/// Parse and validate an SRQL query, returning the AST or translation info.
/// Useful for query validation and debugging.
pub fn translate(query: &str) -> Result<TranslateResult, ServiceError> {
    let ast = parser::parse(query)?;
    Ok(TranslateResult::from(ast))
}

/// Execute an SRQL query against the given connection pool.
/// This is the core execution path without HTTP overhead.
pub async fn execute_query(
    pool: &db::Pool,
    query: &str,
) -> Result<QueryResult, ServiceError> {
    let ast = parser::parse(query)?;
    query::execute(pool, ast).await
}
```

### NIF API Shape
The Elixir module `ServiceRadarWebNG.SRQL` exposes:
- `translate(query_string)` → `{:ok, %TranslateResult{}}` | `{:error, reason}` for debugging and validation
- `execute(query_string, opts)` → `{:ok, results}` | `{:error, reason}` for query execution

### Concurrency + Async
- SRQL uses `tokio` + `diesel-async`; the NIF should run query execution off scheduler threads.
- Options:
  1. **Dirty CPU schedulers** with a dedicated tokio runtime per NIF call (simpler, acceptable for moderate load).
  2. **Async callback pattern**: NIF spawns work on a long-lived tokio runtime, sends result back to caller pid via message (better for high concurrency).
- Initial implementation: dirty schedulers with bounded timeout.

### Safety
- All NIF entry points MUST be panic-safe (`std::panic::catch_unwind`) and return `{:error, {:panic, message}}` rather than crashing the BEAM VM.
- Connection pool is held as a Rustler `ResourceArc` and initialized once at NIF load time.

## Initial UI surfaces (validation-first)
- A minimal LiveView area under `/ng` that:
  - shows DB connection status (simple read query)
  - runs a sample AGE query via `ServiceRadarWebNG.Graph`
  - runs an SRQL translation/execution round-trip via `ServiceRadarWebNG.SRQL`

## Open questions (to resolve before implementation)
- **Auth strategy for side-by-side mode:**
  - Reuse the existing `users` table (if compatible) vs create an `ng_users` table initially to avoid unintended coupling.
  - Recommendation: Start by validating existing JWT tokens issued by `serviceradar-core`; no new user table needed initially.
- **Routing strategy in prod:**
  - Path prefix (`/ng`) vs separate host/subdomain for `serviceradar-web-ng`.
  - Recommendation: Path prefix (`/ng`) for simplicity in initial deployment.

## Resolved decisions
- **SRQL embedding strategy:** Add NIF-friendly public API (`translate`, `execute_query`) to the existing `rust/srql` crate. No separate crate needed—the existing `lib.rs` already makes it a library. The NIF crate (`web-ng/native/srql_nif`) depends on `srql` and calls these functions directly.
