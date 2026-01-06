## 1. Design and Planning
- [ ] 1.1 Inventory tenant-scoped Ash resources and classify shared vs tenant data.
- [ ] 1.2 Confirm no data migration is required; dev/test databases can be rebuilt.

## 2. Schema Isolation Enablement
- [ ] 2.1 Update tenant-scoped Ash resources to use context-based multitenancy.
- [ ] 2.2 Ensure shared resources remain in public schema with attribute multitenancy as needed.
- [ ] 2.3 Add tenant schema creation and tenant migration execution to tenant provisioning flows.

## 3. Startup Migrations
- [ ] 3.1 Add core-elx startup migration runner for public and tenant schemas using Ash migrations.
- [ ] 3.2 Fail core-elx startup if migrations fail.

## 4. Tests and Docs
- [ ] 4.1 Add tests for schema selection and tenant-scoped reads/writes.
- [ ] 4.2 Add tests for startup migration behavior and failure handling.
- [ ] 4.3 Update operator documentation for schema isolation behavior and migration expectations.
