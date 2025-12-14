## 1. Implementation
- [ ] 1.1 Define and document the effective data model for mapper discovery config (seeds, credentials, schedule/enable).
- [ ] 1.2 Reuse existing Core admin config endpoints for mapper config (`GET/PUT /api/admin/config/mapper`, backed by KV `config/mapper.json`) and add any mapper-specific validation/redaction needed for UI-safe reads.
- [ ] 1.3 Define and implement storage for per-interface SNMP polling preferences in KV keyed by `(device_id, if_index)` (or equivalent stable interface identifier).
- [ ] 1.4 Add Core API endpoints to read/update per-interface SNMP polling preferences (Core reads/writes KV; no browser-to-KV).
- [ ] 1.5 Define and implement how SNMP polling configuration is derived from interface preferences (generate effective targets/config, and document whether restart is required).
- [ ] 1.6 Update Network → Discovery UI to:
  - [ ] show “Discovery Configuration” controls
  - [ ] show discovered interfaces with an SNMP polling toggle
  - [ ] show propagation state (“applied” vs “restart required/pending”)
- [ ] 1.7 Add Next.js proxy routes for any new Core endpoints (follow the existing patterns in `web/src/app/api/admin/config/*` and `web/src/app/api/query/route.ts` for auth + `X-API-Key` forwarding).
- [ ] 1.8 Add authorization checks (admin-only or appropriate role) for all write endpoints and UI controls.

## 2. Validation
- [ ] 2.1 Add unit tests for config parsing/validation and redaction on read.
- [ ] 2.2 Add API tests for mapper config CRUD and interface preference CRUD.
- [ ] 2.3 Add a UI smoke test (where patterns exist) for toggling interface SNMP polling.

## 3. Documentation
- [ ] 3.1 Document the UI workflow (Network → Discovery) and where config is stored (KV keys / tables).
- [ ] 3.2 Document operational semantics: when changes require a restart and how to verify effective config.
