## 1. Foundation & Plumbing

### Application & DB
- [ ] 1.1 Scaffold `serviceradar_web_ng` (Phoenix 1.7+, LiveView) in `web-ng/`.
- [ ] 1.2 Configure `Ecto` to connect to the existing CNPG/AGE database.
- [ ] 1.3 Port the Graph Abstraction (`ServiceRadarWebNG.Graph`) from `Guided` to support AGE queries.

### SRQL Engine (Rustler)
- [ ] 1.4 Refactor `rust/srql` to expose public library functions.
- [ ] 1.5 Implement `native/srql_nif` in Phoenix (Async NIF pattern).
- [ ] 1.6 Implement `ServiceRadarWebNG.SRQL` module.

## 2. Authentication (Fresh Implementation)
- [ ] 2.1 Run `mix phx.gen.auth Accounts User ng_users`.
  - [ ] *Note:* Using `ng_users` ensures we do not conflict with the legacy `users` table.
- [ ] 2.2 Run migrations to create the new auth tables.
- [ ] 2.3 Verify registration/login flow works independently of the legacy system.

## 3. Logic Porting (Shared Data)

### Inventory & Infrastructure
- [ ] 3.1 Create Ecto schemas for `unified_devices`, `pollers`, `services` (no migrations).
  - [ ] *Note:* Use `@primary_key {:id, :string, autogenerate: false}`.
  - [ ] *Note:* "No migrations" means Phoenix does not own the table DDL—Go Core does. Phoenix CAN still read/write data to these tables.
- [ ] 3.2 Implement `Inventory.list_devices`.
- [ ] 3.3 Implement `Infrastructure.list_pollers`.

### Edge Onboarding
- [ ] 3.4 Port `EdgeOnboardingPackage` schema (Shared Data).
- [ ] 3.5 Implement token generation logic in Elixir.

## 4. UI & API Implementation

### API Replacement
- [ ] 4.1 Create `ServiceRadarWebNG.Api.QueryController` (SRQL endpoint).
- [ ] 4.2 Create `ServiceRadarWebNG.Api.DeviceController`.

### Dashboard (LiveView)
- [ ] 4.3 Re-implement the main Dashboard using LiveView.
- [ ] 4.4 Implement Device List view.

## 5. Final Cutover
- [ ] 5.1 Update `docker-compose.yml` to expose `web-ng` on port 80/443.
- [ ] 5.2 Remove `kong` container from deployment.
- [ ] 5.3 Remove standalone `srql` HTTP service container from deployment (SRQL is now embedded in Phoenix via Rustler).
