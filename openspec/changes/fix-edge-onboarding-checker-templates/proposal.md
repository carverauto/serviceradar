# Change: Fix edge onboarding missing checker templates and UX

## Why
- Users attempting edge onboarding for checkers (like `sysmon`) encounter an error: "no template found at templates/checkers/sysmon.json and no checker_config_json provided"
- The checkers haven't been updated to register their templates in KV on startup (Phase 2 in checker-template-registration.md is incomplete)
- Users are required to know the exact checker kind names without any guidance - the web UI shows a free-text input instead of a discoverable list
- The only autocomplete available is from previously-created packages, which doesn't help new deployments

## What Changes

### 1. Ship default checker templates in KV seeding
- Add default templates for all supported checkers (`sysmon`, `snmp`, `rperf`, `sweep`, `dusk`, `sysmon-osx`) to the KV seeding process
- Templates will use the existing variable substitution format (`{{VARIABLE}}`) for deployment-specific values
- This provides an immediate fix without requiring each checker to implement template registration

### 2. Add API endpoint to list available checker templates
- New endpoint: `GET /api/admin/checker-templates`
- Returns list of available checker kinds with metadata (name, description, has_template)
- Reads from `templates/checkers/*.json` keys in KV store
- Provides discoverability for both UI and API users

### 3. Update web UI to show checker template dropdown
- Replace free-text input for "Checker kind" with a dropdown populated from the API
- Show loading state while fetching templates
- Fallback to text input if no templates are found (for manual/custom configs)
- Display helpful messaging when templates are missing

## Impact
- Affected specs: edge-onboarding (if exists), kv-configuration
- Affected code:
  - `pkg/core/edge_onboarding.go` - add template listing
  - `web/src/app/admin/edge-packages/page.tsx` - update form UX
  - KV seeding scripts/configs - add default templates
  - `packaging/*/config/checkers/*.json` - ensure all checkers have templates

## Status
- **Blocking bug**: Users cannot onboard sysmon checkers without manually providing full checker_config_json
