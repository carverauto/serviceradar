## 1. Implementation
- [x] 1.1 Audit current Ash resources and migrations for missing `platform` schema targeting and identify all tables landing in `public`.
- [x] 1.2 Update Ash resource definitions to target the `platform` schema consistently.
- [x] 1.3 Add idempotent migrations that move any existing ServiceRadar tables/indexes/sequences from `public` to `platform`.
- [x] 1.4 Update Timescale hypertable/retention migrations to work with `platform, ag_catalog` search_path (schema-qualified functions or extension relocation).
- [x] 1.5 Add core-elx startup validation that fails fast if ServiceRadar tables remain in `public` after migrations.
- [ ] 1.6 Verify clean docker-compose boot with no `public` schema tables and no hypertable errors.
