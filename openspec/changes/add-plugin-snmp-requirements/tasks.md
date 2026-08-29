# Implementation Tasks

Conventions from `add-notification-platform/tasks.md` apply: hand-written
migrations under `elixir/serviceradar_core/priv/repo/migrations/` applied with
`mix ash.migrate` (never `mix ash.codegen`), `prefix: "platform"` on every
table, ASCII-only docs.

## 0. Preconditions (blocking; see proposal.md)

- [ ] 0.1 Sanitize the compiled target name in `build_base_target/5` to
  `[A-Za-z0-9_-]` and truncate, so an FQDN-named device cannot produce an
  invalid target. Add a test using a dotted hostname.
- [ ] 0.2 Decide and implement the behavior for one bad target in
  `ValidateForAgent`: drop-with-warning rather than reject-all, or an
  equivalent guard. Today one bad target disables SNMP for every profile on
  that agent. Add a test proving a good target still polls alongside a bad one.
- [ ] 0.3 Verify 0.1 against a live compile with real ClearPass inventory
  before anything below is enabled in an environment that polls.

## 1. Manifest

- [ ] 1.1 Add `:snmp_requirements` to the `Manifest` defstruct and
  `from_map/1`.
- [ ] 1.2 `validate_snmp_requirements/2`: entry-key allowlist, per-OID key
  allowlist, and explicit rejection of every credential key and every
  polling-control key (`enabled`, `is_default`, `priority`, `agent_ids`,
  `host`, `port`).
- [ ] 1.3 Enforce the agent's own OID rules at parse time: `.1.3.6.1.` prefix
  with numeric arcs, name non-empty and <= 64, `data_type` in the allowlist,
  `mode` in `get|walk`, non-negative `scale`/`max_rows`/`walk_timeout_seconds`.
- [ ] 1.4 Tests: a well-formed block parses; each rejected key is rejected
  individually; a malformed OID is rejected; a package with no block is
  unaffected.

## 2. Schema

- [ ] 2.1 Migration adding `plugin_packages.snmp_requirements` (`{:array,
  :map}`), and `plugin_package_id` on both `snmp_oid_templates` and
  `snmp_profiles` as `references(..., on_delete: :nilify_all)`.
- [ ] 2.2 Add the attributes to the `SNMPOIDTemplate` and `SNMPProfile` Ash
  resources.
- [ ] 2.3 Bump `core.migrations.expectedVersion` in
  `helm/serviceradar/values.yaml`.

## 3. Catalog

- [ ] 3.1 `ServiceRadar.Plugins.SNMPRequirementCatalog`, structurally following
  `alert_rule_catalog.ex`: `sync_package/2`, `disable_package_snmp/2`,
  `find_existing/3` keyed on `(plugin_package_id, name)`.
- [ ] 3.2 Materialize one template + one profile per entry. Force
  `enabled: false`, `is_default: false`, `priority: 0`, `agent_ids: []`, and
  write no credential attribute under any circumstance.
- [ ] 3.3 Namespace every materialized OID name with the package id; add a
  name-level `uniq_by` with a dropped-name warning in `compile_oids/1` so no
  combination of operator-selected templates can produce a duplicate-name
  rejection.
- [ ] 3.4 Split fields: `@template_definition_fields [:description, :category,
  :oids]` updated on every sync; everything else create-only, including
  `oid_template_ids`.
- [ ] 3.5 Return `:ok` before any query when `snmp_requirements` is nil.
- [ ] 3.6 Tests: approve creates inert rows; re-approve after revoke does not
  re-enable; upgrade updates OIDs and preserves all four operator-tunable
  fields; a package with no block is a no-op on every transition.

## 4. Lifecycle wiring

- [ ] 4.1 `packages.ex`: `sync_snmp_requirements(:approved)` on approve,
  `(:disabled)` on deny/revoke/restage - the three call sites that already
  carry `sync_alert_rules`.
- [ ] 4.2 Test each transition end to end.

## 5. UI

- [ ] 5.1 Provenance badge on the profile list row and in the template
  browser's Custom tab, including the package-removed case.
- [ ] 5.2 Show compiled target count on the profile row.
- [ ] 5.3 Warn on enabling a profile with no credential bound.
- [ ] 5.4 LiveView tests for the badge and the no-credential warning.

## 6. Customer-repo follow-up (does not land in this repo)

- [ ] 6.1 Add `snmp_requirements:` to `plugins/clearpass-policy-manager/
  plugin.yaml`, sourced from the verified OID map in
  `config/snmp-clearpass.example.json`.
- [ ] 6.2 Reconcile against live data once approved: confirm the template
  materializes, the profile is disabled, and enabling it with a bound
  credential produces rows.
