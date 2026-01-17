# Proposal: Fix Helm Deployment Bootstrap

## Summary

Make `helm install serviceradar` a single-command deployment that brings up the entire stack without manual intervention. Currently, fresh deployments in the demo-staging namespace have multiple services failing or in CrashLoopBackOff due to TLS certificate trust issues, database schema mismatches, and Elixir process naming conflicts.

## Problem Statement

After a fresh `helm install` in the demo-staging namespace, the following services are unhealthy:

| Service | Status | Root Cause |
|---------|--------|------------|
| serviceradar-web-ng | CrashLoopBackOff | Horde supervisor naming conflict + SSL connection errors |
| serviceradar-core | Running (with errors) | Oban tables in wrong schema (`public` vs `platform`) |
| spire-server | 1/2 Ready | Cannot verify CNPG TLS certificate (x509: certificate signed by unknown authority) |
| db-event-writer | Running (with errors) | Cannot verify CNPG TLS certificate |

Services that ARE healthy: datasvc, nats, cnpg-staging-*, mapper, zen, flowgger, trapd, faker, otel, snmp-checker.

## Root Causes

### 1. CNPG TLS CA Certificate Trust

SPIRE server and db-event-writer connect to CNPG but cannot verify the server certificate:
```
x509: certificate signed by unknown authority (possibly because of "x509: ECDSA verification failure"
while trying to verify candidate authority certificate "cnpg-staging")
```

The CNPG cluster generates its own CA (`cnpg-staging-ca` secret), but:
- SPIRE's PostgreSQL datastore plugin is not configured with the CA bundle path
- db-event-writer is not configured with the CA certificate

### 2. Oban Tables in Wrong Schema

The Ecto migration creates Oban tables in the `public` schema, but the database user's `search_path` is set to `platform,ag_catalog`. When the app queries for `oban_jobs`, it doesn't find them:
```
ERROR 42P01 (undefined_table) relation "oban_jobs" does not exist
```

### 3. Horde Supervisor Naming Conflict (web-ng)

The web-ng app uses the same `ServiceRadar.ProcessRegistry.Supervisor` name that collides with Horde's internal naming. This was already fixed in core-elx but not in web-ng.

## Goals

1. **Idempotent bootstrap**: Fresh `helm install` creates all required infrastructure (schemas, tables, certificates) automatically
2. **Service health**: All pods reach Running/Ready state without manual intervention
3. **TLS trust chain**: All services trust the CNPG CA certificate
4. **Schema isolation**: Oban and application tables live in the correct schema per search_path

## Non-Goals

- Multi-tenant control plane features (handled by separate proposal)
- Production hardening beyond basic functionality
- Performance tuning

## Approach

### Phase 1: Fix CNPG TLS Trust

1. Mount the `cnpg-staging-ca` secret into SPIRE server and configure the datastore plugin with `root_ca` path
2. Mount the `cnpg-staging-ca` secret into db-event-writer and configure TLS root CA
3. Update Helm templates to consistently derive CA secret name from `cnpg.clusterName`

### Phase 2: Fix Oban Schema Migration

1. Update `rebuild_schema.exs` migration to create Oban tables without prefix (uses search_path)
2. Create a migration job that runs before core-elx starts to ensure tables exist
3. Delete the existing `schema_migrations` record so the migration can re-run with new behavior

### Phase 3: Fix web-ng Horde Naming

1. Apply the same `ProcessSupervisor` naming fix to web-ng that was applied to core-elx
2. Rebuild and push the web-ng image

### Phase 4: Validation

1. Delete demo-staging namespace completely (including PVCs)
2. Fresh `helm install`
3. Verify all pods reach Ready state within 5 minutes
4. Verify no error logs in core, web-ng, spire-server, or db-event-writer

## Dependencies

- Existing CNPG cluster provisioning (cnpg-staging-ca secret must exist)
- NATS credentials secret must exist
- Certificate generator job must complete

## Risks

- **Migration version conflict**: If `schema_migrations` record exists, changed migration code won't re-run. Mitigation: Either delete the migration record or use a new migration version.
- **Helm upgrade compatibility**: Changes must not break existing deployments. Mitigation: All changes are additive (mount CA certs, add env vars).

## Related Changes

- `remove-tenant-awareness-from-instance`: Schema isolation work that introduced the `platform` schema
