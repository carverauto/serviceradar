# Tasks

## 1. Manifest
- [x] 1.1 Add `alert_rules` to the manifest struct and type
- [x] 1.2 Validate each entry: name, signal, non-empty match, group_by shape
- [x] 1.3 Reject unknown keys within an entry, matching every existing sibling block
- [x] 1.4 Do NOT accept `enabled` or `priority` — a manifest must not be able to arm a rule

## 2. Materialization
- [x] 2.1 New `AlertRuleCatalog`, modelled on `ProducerScheduleCatalog`
- [x] 2.2 Create disabled, always
- [x] 2.3 Update branch takes only the definition; operator fields structurally excluded
- [x] 2.4 Seed tuning fields on create only, so a plugin can ship starting values
- [x] 2.5 Namespace rule names `plugin:<package>:<name>` so `RuleSeeder` cannot adopt them
- [x] 2.6 Disable rather than delete on deny/revoke/restage

## 3. Wiring
- [x] 3.1 `alert_rules` attribute on `PluginPackage`, plus the upload path
- [x] 3.2 `plugin_package_id` on `StatefulAlertRule`
- [x] 3.3 Hook sync at the approve transition, disable at deny/revoke/restage
- [x] 3.4 Migration: package column, nullable FK, index — `ON DELETE SET NULL`, never cascade

## 4. Tests
- [x] 4.1 Manifest accepts a well-formed rule; omitting the key changes nothing
- [x] 4.2 `enabled` and `priority` are rejected — the security property
- [x] 4.3 Empty match, empty name, unknown signal, empty group_by all rejected
- [x] 4.4 Unknown key within a rule is rejected
- [x] 4.5 Catalog creates disabled and cannot re-sync operator fields
- [x] 4.6 Names are namespaced away from the seeder's defaults
- [x] 4.7 Fixture is a MINIMAL VALID manifest, so error assertions cannot pass on unrelated errors
- [x] 4.8 Verify the two security guards fail when reverted

## 5. Verification
- [x] 5.1 `mix compile` clean
- [x] 5.2 `mix test test/serviceradar/plugins/` — 293 pass
- [x] 5.3 `mix format` / `mix credo --strict` clean
- [x] 5.4 `openspec validate add-plugin-alert-rules --strict`
- [ ] 5.5 **Not run:** end-to-end approve against a live deployment — needs a package to import

## 6. Follow-ups (not this change)
- [ ] 6.1 Top-level unknown manifest keys are silently discarded; `alert_rule:` (singular) would vanish with no error
- [ ] 6.2 A review surface for proposed rules, rather than finding them disabled in the main list
- [ ] 6.3 `camera_relay_*` alert TEMPLATES are seeded but never instantiated, so nothing evaluates them
