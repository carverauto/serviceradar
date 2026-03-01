## 1. Core Settings (DB + Ash)
- [x] 1.1 Add migration for `platform.mapbox_settings` singleton with AshCloak-encrypted `access_token` (`encrypted_access_token` ciphertext column) and derived `access_token_present`.
- [x] 1.2 Add Ash resource `ServiceRadar.Integrations.MapboxSettings` (deployment singleton) with code-interface helpers (`get_settings`, `update_settings`).
- [ ] 1.3 Decide final RBAC permission key for map settings edits (currently piggybacks on settings/integrations manage roles).

## 2. Web-NG Admin UI
- [x] 2.1 Add settings UI (Integrations tab) to save token, enable/disable maps, and show "token saved" state without revealing token.
- [ ] 2.2 Add explicit RBAC gating for the Mapbox tab/actions (align with final permission key from 1.3).

## 3. Reusable Mapbox Component
- [x] 3.1 Add JS hook `MapboxFlowMap` to initialize/destroy a map instance on mount/update.
- [ ] 3.2 Refactor to a reusable HEEx component (currently embedded directly in NetFlow flow details markup).
- [x] 3.3 Implement light/dark mode style switching (style URL from settings + `data-theme` observer).

## 4. NetFlow Integration
- [x] 4.1 In flow details, render the map when GeoIP has coordinates for src/dst IPs.
- [x] 4.2 Add basic labels (source/dest + city/region/country) and fallbacks when coordinates missing.

## 5. Validation
- [ ] 5.1 Add LiveView test coverage for settings page.
- [ ] 5.2 Smoke test the map component in dev routes.
- [ ] 5.3 Run `openspec validate add-mapbox-maps --strict`.
