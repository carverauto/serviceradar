# Change: Fix edge onboarding missing component templates and UX

## Why
- Users attempting edge onboarding for checkers (like `sysmon`) encounter an error: "no template found at templates/checkers/sysmon.json and no checker_config_json provided"
- The checkers haven't been updated to register their templates in KV on startup (Phase 2 in checker-template-registration.md is incomplete)
- Users are required to know the exact checker kind names without any guidance - the web UI shows a free-text input instead of a discoverable list
- The only autocomplete available is from previously-created packages, which doesn't help new deployments

## What Changes

### 1. Ship default checker templates in KV seeding
- Add default templates for all supported checkers (`sysmon`, `snmp`, `rperf`, `dusk`, `sysmon-osx`; sweep N/A) to the KV seeding process
- Compose seeds mTLS-specific templates under `templates/checkers/mtls/`; Helm retains SPIRE templates under `templates/checkers/spire/`
- Templates use the existing variable substitution format (`{{VARIABLE}}`) for deployment-specific values

### 2. Add API endpoint to list available component templates
- New endpoint: `GET /api/admin/component-templates`
- Supports component types (checker/agent/poller) and security modes (mtls/spire) via query params
- Returns template metadata (component_type, kind, security_mode, template_key) discovered from `templates/{component}/{security_mode}/*.json` keys in KV
- Handles KV prefixes containing slashes (filters client-side) to avoid JetStream filter gaps

### 3. Update web UI to show checker template dropdown
- Replace free-text input for "Checker kind" with a dropdown populated from the API
- Include a "Custom" option so users can still enter any checker kind even when templates exist
- Show loading state while fetching templates
- Fallback to text input if no templates are found (for manual/custom configs)
- Display helpful messaging when templates are missing

## Impact
- Affected specs: edge-onboarding (if exists), kv-configuration
- Affected code:
  - `pkg/core/edge_onboarding.go` - add template listing and security-mode aware lookups
  - `pkg/datasvc/nats.go` - robust prefix listing for KV templates
  - `web/src/app/admin/edge-packages/page.tsx` - update form UX with dropdown/custom
  - KV seeding scripts/configs - add default templates (compose mTLS; Helm SPIRE)
  - `packaging/*/config/checkers/*.json` - ensure all checkers have templates

## Status
- **Blocking bug**: Users cannot onboard sysmon checkers without manually providing full checker_config_json
