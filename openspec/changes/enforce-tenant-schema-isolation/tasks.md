## 1. Design and Planning
- [x] 1.1 Inventory tenant-scoped Ash resources and classify shared vs tenant data.
- [x] 1.2 Confirm no data migration is required; dev/test databases can be rebuilt.

## 2. Schema Isolation Enablement
- [x] 2.1 Update tenant-scoped Ash resources to use context-based multitenancy.
- [x] 2.2 Ensure shared resources remain in public schema with attribute multitenancy as needed.
- [x] 2.3 Add tenant schema creation and tenant migration execution to tenant provisioning flows.
- [x] 2.4 Move tenant AshOban schedules/Oban jobs into tenant schemas; keep platform jobs public.

## 3. Startup Migrations
- [x] 3.1 Add core-elx startup migration runner for public and tenant schemas using Ash migrations.
- [x] 3.2 Fail core-elx startup if migrations fail.

## 4. Tests and Docs
- [x] 4.1 Add tests for schema selection and tenant-scoped reads/writes.
- [x] 4.2 Add tests for startup migration behavior and failure handling.
- [x] 4.3 Update operator documentation for schema isolation behavior and migration expectations.
