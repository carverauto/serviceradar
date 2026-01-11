## 1. Create default checker templates

- [x] 1.1 Create `packaging/sysmon/config/checkers/sysmon.json` template with variable substitution placeholders
- [x] 1.2 Create `packaging/sysmon-osx/config/checkers/sysmon-osx.json` template
- [x] 1.3 Verify existing templates (`snmp.json`, `rperf.json`) use consistent variable substitution format
- [x] 1.4 Create `packaging/sweep-checker/config/checkers/sweep.json` if missing (N/A - no sweep checker exists)
- [x] 1.5 Create `packaging/dusk-checker/config/checkers/dusk.json` if missing

## 2. Add KV seeding for checker templates

- [x] 2.1 Update docker-compose KV seeding to include checker templates from packaging directories
- [x] 2.2 Update Helm chart KV seeding ConfigMaps to include checker templates
- [x] 2.3 Verify templates are seeded at `templates/checkers/{security_mode}/{kind}.json` paths (mtls for compose, spire for k8s)
- [x] 2.4 Test that seeded templates work with edge onboarding flow

## 3. Add checker template listing API

- [x] 3.1 Add `ListComponentTemplates` method to `pkg/core/edge_onboarding.go`
- [x] 3.2 Implement KV prefix scan for `templates/checkers/` keys (added `ListKeys` to proto and datasvc)
- [x] 3.3 Add `GET /api/admin/component-templates` endpoint handler
- [x] 3.4 Return template metadata: component_type, kind, security_mode, template_key
- [x] 3.5 Add unit tests for template listing

## 4. Update web UI form

- [x] 4.1 Fetch available templates in edge-packages page
- [x] 4.2 Replace text input with `<select>` dropdown when templates are available
- [x] 4.3 Add loading and error states for template fetch
- [x] 4.4 Fall back to text input when no templates available or when user selects “Custom”
- [x] 4.5 Update helper text to guide users
- [x] 4.6 Test form behavior with no templates, some templates, and API errors

## 5. Documentation and testing

- [x] 5.1 Update `docs/checker-template-registration.md` to reflect the seeding approach
- [ ] 5.2 Add E2E test for checker edge onboarding using default template
- [x] 5.3 Document how to add new checker templates (included in 5.1)
