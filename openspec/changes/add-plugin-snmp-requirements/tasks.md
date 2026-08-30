# Implementation Tasks

Conventions from `add-notification-platform/tasks.md` apply: hand-written
migrations under `elixir/serviceradar_core/priv/repo/migrations/` applied with
`mix ash.migrate` (never `mix ash.codegen`), `prefix: "platform"` on every
table, ASCII-only docs.

## 0. Preconditions (blocking; see proposal.md)

- [x] 0.1 Sanitize the compiled target name in `build_base_target/5` to
  `[A-Za-z0-9_-]` and truncate, so an FQDN-named device cannot produce an
  invalid target. Add a test using a dotted hostname.
- [x] 0.2 Decide and implement the behavior for one bad target in
  `ValidateForAgent`: drop-with-warning rather than reject-all, or an
  equivalent guard. Today one bad target disables SNMP for every profile on
  that agent. Add a test proving a good target still polls alongside a bad one.
- [ ] 0.3 Verify 0.1 against a live compile with real ClearPass inventory
  before anything below is enabled in an environment that polls.

## 1. Manifest

- [x] 1.1 Add `:snmp_requirements` to the `Manifest` defstruct and
  `from_map/1`.
- [x] 1.2 `validate_snmp_requirements/2`: entry-key allowlist, per-OID key
  allowlist, and explicit rejection of every credential key and every
  polling-control key (`enabled`, `is_default`, `priority`, `agent_ids`,
  `host`, `port`).
- [x] 1.3 Enforce the agent's own OID rules at parse time: `.1.3.6.1.` prefix
  with numeric arcs, name non-empty and <= 64, `data_type` in the allowlist,
  `mode` in `get|walk`, non-negative `scale`/`max_rows`/`walk_timeout_seconds`.
- [x] 1.4 Tests: a well-formed block parses; each rejected key is rejected
  individually; a malformed OID is rejected; a package with no block is
  unaffected.

## 2. Schema

- [x] 2.1 Migration adding `plugin_packages.snmp_requirements` (`{:array,
  :map}`), and `plugin_package_id` on both `snmp_oid_templates` and
  `snmp_profiles` as `references(..., on_delete: :nilify_all)`.
- [x] 2.2 Add the attributes to the `SNMPOIDTemplate` and `SNMPProfile` Ash
  resources.
- [x] 2.3 Bump `core.migrations.expectedVersion` in
  `helm/serviceradar/values.yaml`.

## 3. Catalog

- [x] 3.1 `ServiceRadar.Plugins.SNMPRequirementCatalog`, structurally following
  `alert_rule_catalog.ex`: `sync_package/2`, `disable_package_snmp/2`,
  `find_existing/3` keyed on `(plugin_package_id, name)`.
- [x] 3.2 Materialize one template + one profile per entry. Force
  `enabled: false`, `is_default: false`, `priority: 0`, `agent_ids: []`, and
  write no credential attribute under any circumstance.
- [x] 3.3 Namespace every materialized OID name with the package id; add a
  name-level `uniq_by` with a dropped-name warning in `compile_oids/1` so no
  combination of operator-selected templates can produce a duplicate-name
  rejection.
- [x] 3.4 Split fields: `@template_definition_fields [:description, :category,
  :oids]` updated on every sync; everything else create-only, including
  `oid_template_ids`.
- [x] 3.5 Return `:ok` before any query when `snmp_requirements` is nil.
- [x] 3.6 Tests: approve creates inert rows; re-approve after revoke does not
  re-enable; upgrade updates OIDs and preserves all four operator-tunable
  fields; a package with no block is a no-op on every transition.

## 3b. Device-linked fact storage

- [x] 3b.1 Migration creating `device_snmp_facts` with `device_uid`
  referencing `ocsf_devices(uid)` on delete cascade, plus `oid`, `oid_name`,
  `oid_index`, `value` (text), `data_type`, `plugin_package_id`,
  `snmp_profile_id`, and `collected_at`. Unique on
  `(device_uid, oid, oid_index)`.
- [x] 3b.2 `ServiceRadar.Inventory.DeviceSNMPFact` resource; add the
  `has_many :snmp_facts` relationship to `Device`.
- [x] 3b.3 Write facts on ingestion for declared OIDs whose `data_type` is
  `string`, and for every OID regardless of type as current state. Numeric OIDs
  continue to `timeseries_metrics` unchanged.
  **Path traced, and it does not run through core.** The agent drains points in
  `push_loop_snmp.go`, streams them with `Source: "snmp-metrics"`, and
  `ResultsRouter.handle_snmp_metrics/1` deliberately answers
  `{:error, {:gateway_metric_status_not_core_routable, _}}`
  (`results_router.ex:465,871`). The live path is
  `serviceradar_agent_gateway`'s `status_processor.ex:142`
  `publish_snmp_metrics/1`. **Resolved differently than that note predicted**:
  the write landed in `serviceradar_core`'s metric consumer
  (`processors/metrics.ex`) after all, because that is the only point where a
  decoded reading and a resolved `ocsf_devices.uid` coexist - the gateway has no
  database dependency at all. Required an agent change first: string readings
  were being discarded in `marshalSNMPMetricEnvelope` before reaching the wire.
- [x] 3b.4 Tests: a string OID round-trips; walked rows keep distinct
  `oid_index`; facts are deleted with their device; a fact names its package and
  profile.

## 4. Lifecycle wiring

- [x] 4.1 `packages.ex`: `sync_snmp_requirements(:approved)` on approve,
  `(:disabled)` on deny/revoke/restage - the three call sites that already
  carry `sync_alert_rules`.
- [ ] 4.2 Test each transition end to end through `Packages` in `web-ng`. The
  catalog itself is covered directly in `serviceradar_core`; what is untested is
  the three call sites.

## 4b. Fact provenance (follow-up)

- [ ] 4b.1 Thread the collecting profile id through to the reading so
  `device_snmp_facts.snmp_profile_id` and `plugin_package_id` stop being NULL.
  Nothing on the wire links a reading back to its profile today:
  `protoToSNMPConfig` never copies `SNMPTargetConfig.id` into `snmp.Target`, and
  `snmp.Target` has no id field, so this needs a proto and agent change rather
  than inference from the OID name.

## 5. UI

- [x] 5.1 Provenance badge on the profile list row and in the template
  browser's Custom tab, including the package-removed case.
- [x] 5.2 Show compiled target count on the profile row. **Already present** -
  `Data.load_profiles_with_counts/1` and the `Targets` column predate this
  change and already dedupe identical target queries across profiles.
- [x] 5.3 Warn on enabling a profile with no credential bound. Rendered as a
  persistent inline badge rather than a flash: only `:info` and `:error` flashes
  are rendered (`core_components.ex` `attr :kind, values: [:info, :error]`), so a
  `:warning` flash would be silently dropped - and a transient message would also
  miss a profile that was already enabled without a credential, which is the
  state most worth surfacing. Uses `CredentialResolver.record_has_credential?/1`,
  made public so the warning cannot drift from the resolver.
- [x] 5.4 LiveView tests for the badge and the no-credential warning.

## 6. Customer-repo follow-up (does not land in this repo)

- [ ] 6.1 Add `snmp_requirements:` to `plugins/clearpass-policy-manager/
  plugin.yaml`, sourced from the verified OID map in
  `config/snmp-clearpass.example.json`.
- [ ] 6.2 Confirm the ClearPass string OIDs (node version, node role, service
  names) land in `device_snmp_facts` against the right device, since these are
  the values that have nowhere to go today.
- [ ] 6.3 Reconcile against live data once approved: confirm the template
  materializes, the profile is disabled, and enabling it with a bound
  credential produces rows.
