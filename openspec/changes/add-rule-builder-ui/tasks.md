## 1. Data Model & Sync
- [ ] 1.1 Add tenant-scoped Ash resource for Zen rules (builder config + compiled JDM + KV revision)
- [ ] 1.2 Add migrations for Zen rule storage
- [ ] 1.3 Implement KV sync service (create/update/delete + startup reconciliation)
- [ ] 1.4 Add validation for subject, format, and rule template constraints

## 2. API Layer
- [ ] 2.1 Expose CRUD actions for Zen rules via core-elx API
- [ ] 2.2 Expose CRUD actions for LogPromotionRule and StatefulAlertRule for UI use
- [ ] 2.3 Add read-only endpoints for rule evaluation history (stateful engine)

## 3. Web UI (web-ng)
- [ ] 3.1 Add shared Settings layout + left navigation and route all settings under `/settings/*`
- [ ] 3.2 Move existing settings pages to the shared Settings layout (keep `/users/settings` alias or redirect)
- [ ] 3.3 Add "Event Notifications & Response Rules" settings page
- [ ] 3.4 Build Log Normalization rule builder (syslog/snmp/otel/internal)
- [ ] 3.5 Build Response Rules builder for stateful alerts
- [ ] 3.6 Add rule list, enable/disable, and inline validation feedback

## 4. Docs & Examples
- [ ] 4.1 Add Rule Builder guide (how to build normalization + response rules)
- [ ] 4.2 Update syslog/snmp docs to reference the UI workflow
- [ ] 4.3 Document KV sync and reconciliation behavior

## 5. Tests
- [ ] 5.1 Core unit tests for rule validation + KV sync
- [ ] 5.2 Web-ng LiveView tests for rule CRUD flows
