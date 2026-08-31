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
- [x] 0.3 Verify 0.1 against a live compile with real ClearPass inventory
  before anything below is enabled in an environment that polls.

  **Verified against the live estate.** 16,437 of 22,592 active `ocsf_devices`
  rows - 73% - carry a character `isValidNameChar` rejects in
  `name`/`hostname`/`uid`. Real examples:
  `host01 @ 00:00:5e:00:53:03 [ews]`, `host02 [windows
  server]`, and every synthetic `sr:<uuid>` uid. The single configured profile
  is `Default SNMP`, `enabled`, `is_default`, `target_query: in:devices` - it
  matches all of them, so under the old code the first such device would have
  failed `ValidateForAgent` and taken the whole agent's SNMP config down.

  Both fixes ship in the deployed `v1.4.49`. A live compile could not be
  observed producing sanitized names because that profile has **no credential of
  any kind** (no community, no v3 user, no `credential_secret_id`), so it
  compiles to zero targets: `device_snmp_facts` is empty and the agent logs no
  SNMP activity at all. That is the same silent-nothing state task 5.3's warning
  now surfaces, and it is live today.

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
- [x] 4.2 Test each transition end to end through `Packages` in `web-ng`. The
  catalog itself is covered directly in `serviceradar_core`; what is untested is
  the three call sites.

## 4b. Fact provenance (follow-up)

- [x] 4b.1 Thread the collecting profile id through to the reading so
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

## 5b. Known gap: a plugin cannot alert on its own declared OID

- [ ] 5b.1 Decide how an `alert_rules:` entry references a metric produced by
  the same package's `snmp_requirements:`.

  The catalog namespaces every materialized OID name by `plugin_id`
  (`snmp_requirement_catalog.ex`), and that namespaced name is what reaches
  `timeseries_metrics.metric_name` - `parseSNMPMetricName/1` only splits on
  `::`, so it passes the name through unchanged. A manifest author writes
  `service_port` but the metric is `clearpass-policy-manager_service_port`,
  and the manifest has no way to spell "the namespaced form of the OID I
  declared".

  So a rule can only match by hardcoding the post-namespacing string, which
  duplicates the catalog's naming rule in every manifest and breaks silently if
  it ever changes. Surfaced by fjb-network-monitor#32's `service-stopped` rule,
  which watches `clearpass.service.up` - a metric the REST plugin declares but
  can never emit, because its only source endpoint is 404 on every ClearPass in
  the estate (fjb-network-monitor#36).

  Options, none chosen: hardcode the namespaced name; add a manifest-relative
  reference core resolves at materialization; or stop namespacing and handle
  OID-name collisions another way.

## 6. Customer-repo follow-up (does not land in this repo)

- [x] 6.1 Add `snmp_requirements:` to `plugins/clearpass-policy-manager/
  plugin.yaml`, sourced from the verified OID map in
  `config/snmp-clearpass.example.json`. Landed as Example-Airline-Org/
  fjb-network-monitor#35, verified by running the real file through
  `Manifest.from_yaml/1` and `SNMPRequirementCatalog.sync_package/2`.
- [ ] 6.2 (blocked: the ClearPass package is not imported. The estate has two
  approved packages, both `opentext-nom-inventory` 0.1.4/0.1.6, and neither
  declares `snmp_requirements`.)
  Confirm the ClearPass string OIDs (node version, node role, service
  names) land in `device_snmp_facts` against the right device, since these are
  the values that have nowhere to go today.
- [ ] 6.3 (blocked: same) Reconcile against live data once approved: confirm the template
  materializes, the profile is disabled, and enabling it with a bound
  credential produces rows.
