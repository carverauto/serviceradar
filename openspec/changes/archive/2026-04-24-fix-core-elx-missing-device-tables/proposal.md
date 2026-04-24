# Change: Fix core-elx mapper and sweep ingestion failing due to search_path misconfiguration

## Why

Core-elx in the demo namespace (k8s) is failing to process mapper and sweep results because the PostgreSQL `search_path` is incorrectly configured with quoted values, causing queries to fail to find tables in the `platform` schema.

Errors from issue #2574:
```
Device UID lookup failed: relation "ocsf_devices" does not exist
Bulk identifier lookup failed: relation "device_identifiers" does not exist
Bulk device upsert failed: relation "ocsf_devices" does not exist
```

**Root cause**: The `ensure_database_search_path!` function in `startup_migrations.ex` uses `quote_literal()` to wrap the search_path value in single quotes:
```sql
ALTER DATABASE "serviceradar" SET search_path TO 'platform, public, ag_catalog'
```

PostgreSQL interprets this as a single identifier (with spaces and commas in the name), storing it as `"platform, public, ag_catalog"` with double quotes. The effective search_path becomes a non-existent schema name instead of three separate schemas.

The tables exist in `platform` schema, but Ash queries (without schema prefix) can't find them because the search_path doesn't resolve to `platform`.

Reference: GitHub issue #2574

## What Changes

1. **Fix search_path SQL syntax** - The `ensure_database_search_path!` function SHALL NOT quote the search_path value. The SQL should be:
   ```sql
   ALTER DATABASE "serviceradar" SET search_path TO "platform", "public", "ag_catalog"
   ALTER ROLE "serviceradar" SET search_path TO "platform", "public", "ag_catalog"
   ```

2. **Fix existing deployments** - The startup migrations SHALL detect and correct misconfigured search_path values.

3. **Grant AGE graph schema privileges** - The `ensure_ag_catalog_privileges!` function SHALL also grant privileges on the AGE graph schema (`serviceradar`) so the app role can execute Cypher queries.

## Impact

- Affected specs: `cnpg`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex` - Fix search_path SQL syntax and AGE privileges

## Related Changes

- `fix-helm-deployment-bootstrap` - Broader helm deployment bootstrap fixes
- `remove-public-schema-usage` - Platform schema migration (5/6 tasks complete)
