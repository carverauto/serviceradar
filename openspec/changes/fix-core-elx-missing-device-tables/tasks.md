# Tasks: Fix core-elx mapper and sweep ingestion failing

## 1. Fix search_path SQL syntax

- [x] 1.1 Update `ensure_database_search_path!/3` to use `format_search_path/1` that quotes each schema individually
- [x] 1.2 Add `fix_search_path!/2` function that detects and resets misconfigured search_path (starts with `"`)
- [x] 1.3 Call `fix_search_path!/2` during startup migrations to fix existing deployments

## 2. Fix AGE graph schema privileges

- [x] 2.1 Add `ensure_age_graph_privileges!/2` function to grant privileges on the AGE graph schema
- [x] 2.2 Call from `ensure_ag_catalog_privileges!/1` to grant privileges on `serviceradar` graph schema

## 3. Testing

- [x] 3.1 Verify search_path is set correctly after fix: `platform, public, ag_catalog` (no quoted identifier)
- [ ] 3.2 Verify sweep/mapper ingestion works after search_path fix
- [ ] 3.3 Verify interface graph upserts work after AGE permissions fix
