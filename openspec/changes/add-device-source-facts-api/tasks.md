## 1. Spec
- [x] 1.1 Add the `source-fact-reconciliation` delta for externally reported source facts.
- [x] 1.2 Validate with `openspec validate add-device-source-facts-api --strict`.

## 2. Core
- [x] 2.1 `SourceFacts.api_source/1`, `reported_key/1` and `parse_reported/2`: label rules, the `api:` prefix, value validation with reasons (VLAN 1-4094, field sizes).
- [x] 2.2 `Reconciler.report/5`, `retract/5` and `snapshot/4`. A report touches only its own key; a withdrawal clears a canonical value that no present source still reports.
- [x] 2.3 `SourceFacts.Reports`: caller-derived instance, live-device check, argument errors.
- [x] 2.4 `Device` generic actions `:report_source_fact` and `:retract_source_fact`, gated by the new `devices.source_facts.write` catalog permission.

## 3. API
- [x] 3.1 `PUT` and `DELETE /api/devices/:uid/source-facts/:fact_key` in the `/api` scope next to the device facts routes.
- [x] 3.2 Map errors: 400 for a missing parameter or malformed uid, 403 for a missing permission, 404 for an unknown device, 422 for an invalid value.

## 4. Tests
- [x] 4.1 Pure tests for label, key and value validation.
- [x] 4.2 DB tests for promotion, disagreement with an integration, caller isolation, withdrawal and canonical clearing.
- [x] 4.3 Controller tests for the routes, permissions and error mapping.

## 5. Docs
- [x] 5.1 `docs/docs/device-source-facts.md`, linked from the device facts and API reference pages and the sidebar.
