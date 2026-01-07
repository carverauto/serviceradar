## 1. Design and Planning
- [x] 1.1 Inventory tenant-scoped Ash resources and classify shared vs tenant data.
- [x] 1.2 Confirm no data migration is required; dev/test databases can be rebuilt.
- [x] 1.3 Confirm public schema scope (platform resources + tenant memberships) and tenant schema scope (including users/tokens, platform tenant).

## 2. Schema Isolation Enablement
- [x] 2.1 Update tenant-scoped Ash resources to use context-based multitenancy.
- [x] 2.2 Ensure shared resources remain in public schema (tenants, tenant memberships, platform NATS/Oban), while tenant-scoped identity data (ng_users, api/user tokens) stays in tenant schemas.
- [x] 2.3 Add tenant schema creation and tenant migration execution to tenant provisioning flows.
- [x] 2.4 Move tenant AshOban schedules/Oban jobs into tenant schemas; keep platform jobs public.
- [x] 2.5 Reset migrations/snapshots and regenerate baseline public + tenant migrations (scorched earth).
- [x] 2.6 Remove request-supplied tenant headers and derive tenant context from scope or onboarding tokens in web-ng API flows.
- [x] 2.7 Remove default tenant fallbacks in onboarding packages/events and require explicit tenant context.

## 3. Startup Migrations
- [x] 3.1 Add core-elx startup migration runner for public and tenant schemas using Ash migrations.
- [x] 3.2 Fail core-elx startup if migrations fail.
- [x] 3.3 Update integration test runner to use Ash migrations (ash.migrate).

## 4. Tests and Docs
- [ ] 4.1 Update tests for schema selection and tenant-scoped reads/writes, including token-derived tenant lookups (run + verify).
- [ ] 4.2 Update tests for startup migration behavior and failure handling (run + verify).
- [ ] 4.3 Update operator documentation for schema isolation behavior and migration expectations.
- [ ] 4.4 Re-run integration tests against srql-fixtures once DB reset is confirmed.
