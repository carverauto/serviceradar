## 1. Implementation
- [x] 1.1 Document supported JSON Schema subset for plugin configuration
- [x] 1.2 Persist `config_schema` (Ash `:map`) on plugin package versions and expose it via API
- [x] 1.3 Add LiveView component to render schema-driven forms
- [x] 1.4 Wire dynamic form into plugin package create/assign flows
- [x] 1.5 Validate submitted config against schema via Ash changes/calculations and surface errors
- [x] 1.6 Define plugin result display contract (schema version + widget registry)
- [x] 1.7 Render plugin result views on Services page using the display contract
- [x] 1.8 Add safe widget rendering component registry (status badge, stat card, table, markdown, sparkline)
- [x] 1.9 Add layout hints for widget instructions (`layout: full|half`)
- [x] 1.10 Add CSP guidance/implementation (`put_secure_browser_headers` or `plug_csp`)
- [x] 1.11 Add schema version support in plugin manifests/results
- [x] 1.12 Add tests for schema validation and UI rendering

## 2. Validation
- [x] 2.1 Run `openspec validate add-plugin-config-ui --strict`
