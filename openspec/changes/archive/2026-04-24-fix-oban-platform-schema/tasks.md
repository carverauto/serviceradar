# Tasks: Fix Oban Platform Schema

## 1. Update Existing Migration

- [x] 1.1 Rewrite `ensure_oban_platform_tables.exs` migration to be idempotent and handle all edge cases:
  - Tables exist in platform schema only (no-op)
  - Tables exist in public schema only (migrate to platform)
  - Tables exist in both schemas (verify platform is correct)
  - Tables exist in neither schema (create fresh in platform)
- [x] 1.2 Add proper error handling and logging to the migration
- [x] 1.3 Ensure migration creates all Oban objects: `oban_jobs`, `oban_peers`, sequences, and indexes

## 2. Add Startup Validation

- [x] 2.1 Create `ServiceRadar.Oban.SchemaValidator` module to verify Oban tables exist in platform schema
- [x] 2.2 Add validation call in `startup_migrations.ex` before returning success
- [x] 2.3 Log clear error messages if validation fails, including remediation steps

## 3. Improve Application Startup

- [x] 3.1 Update `startup_migrations.ex` to delay Oban startup until schema validation passes
- [ ] 3.2 Add telemetry events for migration/validation success/failure
- [ ] 3.3 Consider adding a `--repair-schema` CLI command for manual remediation

## 4. Testing

- [ ] 4.1 Test fresh install with empty database (no schemas)
- [ ] 4.2 Test upgrade from existing install with tables in public schema
- [ ] 4.3 Test normal startup with correctly configured platform schema
- [ ] 4.4 Add integration test for the migration path

## 5. Documentation

- [ ] 5.1 Add troubleshooting section to docs for this error
- [ ] 5.2 Update docker-compose documentation with any new environment variables
