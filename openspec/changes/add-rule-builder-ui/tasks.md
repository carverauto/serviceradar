## 1. Data Model & Sync
- [x] 1.1 Add tenant-scoped Ash resource for Zen rules (builder config + compiled JDM + KV revision)
- [x] 1.2 Add migrations for Zen rule storage
- [x] 1.3 Implement KV sync service (create/update/delete + startup reconciliation)
- [x] 1.4 Add validation for subject, format, and rule template constraints
- [x] 1.5 Add tenant-scoped template resources for Zen rules and response rules (promotion/stateful)
- [x] 1.6 Add migrations and default template seeding per tenant
- [x] 1.7 Seed default Zen rules during tenant onboarding (including platform tenant)
- [x] 1.8 Add scheduled reconciliation to re-publish Zen rules from DB to KV
- [x] 1.9 Update Zen rule/template identities to include subject and add passthrough defaults for all supported subjects
- [x] 1.10 Remove stale KV entries when Zen rule key fields change (rename or subject update)

## 2. API Layer
- [x] 2.1 Expose CRUD actions for Zen rules via core-elx API
- [x] 2.2 Expose CRUD actions for LogPromotionRule and StatefulAlertRule for UI use
- [x] 2.3 Add read-only endpoints for rule evaluation history (stateful engine)
- [x] 2.4 Expose CRUD actions for template resources (Zen + response)

## 3. Web UI (web-ng)
- [x] 3.1 Add shared Settings layout + tab navigation and route all settings under `/settings/*`
- [x] 3.2 Move existing settings pages to the shared Settings layout (keep `/users/settings` alias or redirect)
- [x] 3.3 Add "Events" settings page
- [x] 3.4 Build Log Normalization rule builder (syslog/snmp/otel/internal)
- [x] 3.5 Build Response Rules builder for stateful alerts
- [x] 3.6 Add rule list, enable/disable, and inline validation feedback
- [x] 3.7 Add template library UI for Zen rules with create/edit flows
- [x] 3.8 Add template library UI for promotion/stateful rules and allow selecting a template when creating/editing rules
- [x] 3.9 Extend Zen subject pickers to include OTEL metrics passthrough defaults

## 4. Docs & Examples
- [x] 4.1 Add Rule Builder guide (how to build normalization + response rules)
- [x] 4.2 Update syslog/snmp docs to reference the UI workflow
- [x] 4.3 Document KV sync and reconciliation behavior
- [x] 4.4 Document template library usage and default templates

## 5. Tests
- [x] 5.1 Core unit tests for rule validation + KV sync
- [x] 5.2 Web-ng LiveView tests for rule CRUD flows
- [x] 5.3 Tests for template CRUD and template-to-rule workflows
