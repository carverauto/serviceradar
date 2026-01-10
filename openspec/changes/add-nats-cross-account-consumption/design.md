# Design: Cross-Account NATS Consumption

## Context
- Tenant NATS accounts isolate JetStream streams per account.
- Subject mappings only rewrite subjects inside the same account.
- Platform consumers (serviceradar-zen, event-writer) currently run in the platform account.

## Goals / Non-Goals

### Goals
- Allow platform ETL consumers to read tenant logs/events without per-tenant deployments.
- Preserve tenant isolation (no tenant-to-tenant access).
- Keep collector configs unchanged (still publish to unprefixed subjects).

### Non-Goals
- Per-tenant NATS clusters.
- Bypassing NATS account isolation.
- Replacing zen with a new ETL system.

## Decisions

### Decision 1: Use Stream Exports + Platform Imports
Each tenant account will export tenant-prefixed streams (logs/events/otel). The platform account will import those exports and expose them with the same tenant-prefixed subjects.

- Tenant export examples:
  - `acme.logs.>`
  - `acme.events.>`
  - `acme.otel.>`

- Platform import examples:
  - Import `acme.logs.>` from account `acme`
  - Import `acme.events.>` from account `acme`
  - Import `acme.otel.>` from account `acme`

**Why**: This keeps tenant prefixes intact, lets a single platform consumer subscribe to `*.logs.>` and `*.events.>`, and avoids per-tenant zen instances.

### Decision 2: Tenant Identity from Subject Prefix
Shared consumers will extract the tenant slug from the first subject token (already required by tenant prefixing). This tenant slug becomes the routing key for database writes and promotion rules.

### Decision 3: Provisioning Updates Platform Imports
When a tenant NATS account is created or revoked, core-elx will update the platform account JWT to add or remove imports for that tenant.

## Risks / Trade-offs
- Platform account imports scale linearly with tenants. Mitigation: keep import list minimal and handle updates in provisioning jobs.
- Misconfigured exports/imports can hide traffic from platform consumers. Mitigation: add validation checks and operator docs.

## Migration Plan
1. Add exports to tenant account JWT generation and re-sign existing tenant accounts.
2. Add platform imports for all existing tenants and re-sign the platform account JWT.
3. Update zen subscriptions to `*.logs.>` and `*.events.>`.
4. Validate end-to-end ingestion for at least two tenants.

## Open Questions
- Should imports be limited to a dedicated platform ETL account (instead of the general platform account)?
- Do we need per-tenant rate limits on exports/imports at launch?
