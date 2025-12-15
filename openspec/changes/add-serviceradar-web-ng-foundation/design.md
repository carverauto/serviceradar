# Design: `serviceradar-web-ng` functionality map

## Philosophy: "The Core is a Daemon"
The Go application (`serviceradar-core`) is treated strictly as a **Data Ingestion Engine**. It scans networks, receives SNMP traps/Netflow, and writes to Postgres. It does **not** serve user traffic.

Phoenix (`serviceradar-web-ng`) reads that ingestion data and serves the UI/API using its own isolated application state.

## 1. Logic Porting Map (Go -> Elixir)
The following domains must be re-implemented. Note that Auth is a *replacement*, not a port.

| Domain | Legacy Go Source | Elixir Context (`ServiceRadarWebNG.*`) | Responsibility |
| :--- | :--- | :--- | :--- |
| **Inventory** | `unified_devices.go` | `Inventory` | Listing devices, Editing metadata (Shared Data). |
| **Topology** | `cnpg_discovery.go` | `Topology` | Querying the Apache AGE graph (Shared Data). |
| **Edge** | `edge_onboarding.go` | `Edge` | CRUD for onboarding packages (Shared Data). |
| **Infra** | `pollers.go` | `Infrastructure` | Viewing Poller status/health (Shared Data). |
| **Auth** | `auth.go` | `Accounts` | **NEW:** Fresh user management table (`ng_users`). |

## 2. Authentication Strategy (Fresh Start)
- **Table:** Create a new table `ng_users` (or similar) via `phx.gen.auth`.
- **Isolation:** Do NOT touch the legacy `public.users` table used by Go. This prevents collision and allows the Go daemon to continue internal operations if it relies on that table (though it shouldn't for ingestion).
- **Setup:** The first user to access the new UI will register a fresh admin account.

## 3. The API Gateway (Internal)
Phoenix will mount a `ServiceRadarWebNG.Api` scope.
- `POST /api/query` -> `QueryController.execute` (Calls Rust NIF).
- All other legacy endpoints are deprecated and replaced by LiveView or new JSON endpoints as needed.

## 4. Embedded SRQL (Rustler)
We are transforming `srql` from a **standalone HTTP service** to an **embedded library**.
- **No removal:** The `rust/srql` crate stays in the repo and continues to be maintained.
- **Refactor:** Ensure `rust/srql/src/lib.rs` exposes `QueryEngine` as a public API (decoupled from the `axum` HTTP layer).
- **NIF:** Phoenix calls into SRQL via Rustler. The Elixir app initializes the Rust runtime once.
- **Flow:** `UI -> Phoenix -> Rustler -> SRQL Lib -> Shared DB`.
- **Deployment change:** The standalone `srql` HTTP container is no longer needed—queries go through Phoenix.

## 5. Schema Ownership vs Data Access
- **Schema ownership (DDL):** Go Core owns the table structure for `unified_devices`, `pollers`, metrics, etc. Phoenix does NOT generate migrations for these.
- **Data access (DML):** Phoenix CAN read AND write to shared tables (e.g., editing device names, updating policies).
- **Phoenix-owned tables:** `ng_users`, `ng_sessions`, etc. Phoenix owns both schema and data.

## 6. Deployment
- The `web-ng` container will be deployed alongside `core`.
- `core` writes to DB (Telemetry/Inventory ingestion).
- `web-ng` reads/writes DB (Inventory edits, Auth, Settings).
- External Load Balancer routes traffic to `web-ng`.
