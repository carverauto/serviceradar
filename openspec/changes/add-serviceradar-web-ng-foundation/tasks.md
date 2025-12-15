## 1. Foundation & Plumbing

### Application & DB
- [x] 1.1 Scaffold `serviceradar_web_ng` (Phoenix 1.7+, LiveView) in `web-ng/`.
- [x] 1.2 Configure `Ecto` to connect to the existing CNPG/AGE database.
  - [x] *Note:* Support remote dev via `CNPG_*` env vars + TLS client certs.
  - [x] *Note:* Publish CNPG for workstation access via Compose `CNPG_PUBLIC_BIND`/`CNPG_PUBLIC_PORT` and cert SANs via `CNPG_CERT_EXTRA_IPS`.
- [x] 1.3 Port the Graph Abstraction (`ServiceRadarWebNG.Graph`) from `Guided` to support AGE queries.
  - [x] *Note:* Add `mix graph.ready` to validate AGE connectivity.

### SRQL Engine (Rustler)
- [x] 1.4 Refactor `rust/srql` to expose public library functions.
- [x] 1.5 Implement `native/srql_nif` in Phoenix (Async NIF pattern).
- [x] 1.6 Implement `ServiceRadarWebNG.SRQL` module.

### Property-Based Testing (StreamData)
- [x] 1.7 Add `stream_data` (and `ExUnitProperties`) to the `web-ng` ExUnit suite.
  - [x] Add the dependency to `web-ng/mix.exs` (`stream_data`) under `only: :test`.
  - [x] Ensure `ExUnitProperties` is available in tests.
- [x] 1.8 Integrate property-based testing into the `web-ng` ExUnit suite.
  - [x] Add shared generators under `web-ng/test/support/generators/`.
  - [x] Add `web-ng/test/property/` with at least one starter property test.
  - [x] Ensure `mix test` runs property tests by default with bounded case-counts and an env override for deeper runs.

## 2. Authentication (Fresh Implementation)
- [x] 2.1 Run `mix phx.gen.auth Accounts User ng_users`.
  - [x] *Note:* Using `ng_users` ensures we do not conflict with the legacy `users` table.
- [x] 2.2 Run migrations to create the new auth tables.
  - [x] *Note:* Use a dedicated Ecto migration source table to avoid collisions in shared CNPG (e.g., `ng_schema_migrations`).
- [x] 2.3 Verify registration/login flow works independently of the legacy system.

## 3. Logic Porting (Shared Data)

### Inventory & Infrastructure
- [ ] 3.1 Create Ecto schemas for `unified_devices`, `pollers`, `services` (no migrations).
  - [x] *Note:* Use `@primary_key {:id, :string, autogenerate: false}`.
  - [x] *Note:* "No migrations" means Phoenix does not own the table DDL—Go Core does. Phoenix CAN still read/write data to these tables.
  - [x] 3.1a Add `unified_devices` schema.
  - [x] 3.1b Add `pollers` schema.
  - [ ] 3.1c Add `services` schema.
- [x] 3.2 Implement `Inventory.list_devices`.
- [x] 3.3 Implement `Infrastructure.list_pollers`.

### Edge Onboarding
- [ ] 3.4 Port `EdgeOnboardingPackage` schema (Shared Data).
- [ ] 3.5 Implement token generation logic in Elixir.
  - [ ] 3.5a Add property tests for token encode/decode invariants (round-trip, URL-safe encoding, and invalid input handling).

## 4. UI & API Implementation

### API Replacement
- [x] 4.1 Create `ServiceRadarWebNG.Api.QueryController` (SRQL endpoint).
  - [x] 4.1a Add property tests for request validation/decoding to ensure malformed JSON and random inputs never crash the endpoint.
- [ ] 4.2 Create `ServiceRadarWebNG.Api.DeviceController`.
  - [ ] 4.2a Include property tests for any new parsing/validation logic introduced by the device API (IDs, filters, and pagination).

### Dashboard (LiveView)
- [ ] 4.3 Re-implement the main Dashboard using LiveView.
- [x] 4.4 Implement Device List view.
  - [x] *Note:* Add authenticated `GET /devices` backed by `Inventory.list_devices`.
- [x] 4.5 Implement Poller List view.
  - [x] *Note:* Add authenticated `GET /pollers` backed by `Infrastructure.list_pollers`.

## 5. Final Cutover
- [ ] 5.1 Update `docker-compose.yml` to expose `web-ng` on port 80/443.
- [ ] 5.2 Remove `kong` container from deployment.
- [ ] 5.3 Remove standalone `srql` HTTP service container from deployment (SRQL is now embedded in Phoenix via Rustler).
