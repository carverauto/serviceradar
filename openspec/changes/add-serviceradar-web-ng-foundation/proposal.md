# Change: Add `serviceradar-web-ng` (The New Monolith)

## Why
- **Complete Replacement:** We are replacing the existing React/Next.js frontend and the Go HTTP API entirely. The new Phoenix application will be the sole interface for users and API clients.
- **Architecture Shift:** Moving from Microservices (Kong + Go API + Rust Service + Next.js) to a Monolith (Phoenix + Embedded Rust).
- **Core Isolation:** `serviceradar-core` (Go) is being demoted to a background ingestion daemon. It will continue to write to the DB, but its HTTP endpoints will be bypassed and eventually ignored.
- **Simplification:** We are removing the need for the Kong API Gateway and the standalone SRQL HTTP service container. SRQL itself remains—it becomes an embedded library called via Rustler NIF.

## What Changes
- **New App:** Create `web-ng/` hosting `:serviceradar_web_ng`.
- **SRQL:** Embed `rust/srql` via Rustler (NIF) to run queries directly within the Phoenix VM, exposing a standard `ServiceRadarWebNG.SRQL` module.
- **Database:** Connect Ecto to the existing Postgres/AGE instance.
  - *Telemetry Data:* Mapped to existing tables (Read-Only).
  - *App Data:* Fresh tables created/managed by Phoenix (Read/Write).
- **Auth:** **Fresh Start.** Implement standard `phx.gen.auth` using a new table (e.g., `ng_users`). We will **not** use the legacy `users` table or migrate old credentials.
- **Logic Porting:** Re-implement user-facing business logic from Go into Elixir Contexts.
- **Testing:** Establish property-based testing patterns early using `StreamData` (`ExUnitProperties`) for core invariants (token formats, parsing/validation, and “never crash” boundaries like NIF input handling).

## Non-Goals
- **No Go Changes:** We will not modify `serviceradar-core` source code.
- **No Auth Migration:** Legacy user accounts are abandoned. Users will register fresh accounts in the new system.
- **No API Compatibility:** The new API will follow Phoenix conventions, not strictly mimic the legacy Go API structure.

## Impact
- **Routing:** Nginx will eventually route `/*` and `/api/*` to Phoenix.
- **Security:** Phoenix becomes the sole Authority for Identity.
- **Performance:** Elimination of internal HTTP hops for Query and API responses.

## Status
- In progress (Foundation + Auth + initial list views).
