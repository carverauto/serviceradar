## 1. Implementation
- [ ] 1.1 Document supported JSON Schema subset for plugin configuration
- [ ] 1.2 Persist `config_schema` on plugin package versions and expose it via API
- [ ] 1.3 Add LiveView component to render schema-driven forms
- [ ] 1.4 Wire dynamic form into plugin package create/assign flows
- [ ] 1.5 Validate submitted config against schema and surface errors
- [ ] 1.6 Define plugin result display contract and supported widgets
- [ ] 1.7 Render plugin result views on Services page using the display contract
- [ ] 1.8 Add safe widget rendering component registry and CSP guidance
- [ ] 1.9 Add tests for schema validation and UI rendering

## 2. Validation
- [ ] 2.1 Run `openspec validate add-plugin-config-ui --strict`
