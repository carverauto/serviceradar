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

## 5b. A plugin alerting on its own declared OID

- [x] 5b.1 **Decided: a manifest-relative `snmp_oid:` reference, validated at
  import and resolved at materialization.** An `alert_rules` entry refers to an
  OID by the name the author wrote in the same package's `snmp_requirements`,
  and core resolves it to the materialized name:

  ```yaml
  snmp_requirements:
    - name: clearpass-service-health
      oids:
        - oid: .1.3.6.1.4.1.14823.1.6.1.1.1.1.4
          name: service_port          # declared name, unqualified
          data_type: gauge
          mode: walk

  alert_rules:
    - name: service-port-unreachable
      signal: metric
      match:
        metric_name:
          snmp_oid: service_port      # -> clearpass-policy-manager_service_port
        condition:
          comparison: lt              # NOT `op:` - see 5b.3
          threshold: 1
  ```

  A plain string in `match.metric_name` stays legal and passes through
  untouched: a rule may legitimately match a metric this package does not
  declare (a core builtin such as `ifInOctets`, hardcoded in
  `god_view_stream.ex:63` and `interface_data.ex:609-620`). Nothing written
  before this change breaks, and no data or DB migration is needed.

  **Why not hardcode the namespaced name (option A).** The materialized name is
  not a pure function of the entry in front of the author. `oid_namespace/1`
  slugs `plugin_id` and caps it at 32 chars (`snmp_requirement_catalog.ex:256-265`,
  `@max_oid_namespace_length` :54); `namespaced_oid_name/2` truncates the joined
  string to 64 (:267-274, `@max_oid_name_length` :50); and `disambiguate/2`
  appends 8 hex chars of `sha256(oid)` when truncation collides (:279-287), which
  the author would have to simulate across sibling OIDs.
  `clearpass-policy-manager_service_port` happens to be hand-derivable; a longer
  plugin id or OID name is not. And a wrong literal fails *silently*: the only
  check on `match` is `is_map(match) and map_size(match) > 0`
  (`manifest.ex:1153-1160`), and `AlertRuleCatalog` copies it through verbatim
  (`alert_rule_catalog.ex:103`).

  **Why not stop namespacing (option C).** Namespacing is currently the only
  thing standing between a duplicate OID name and `errOIDDuplicate`
  (`go/pkg/agent/snmp/config.go:199`) - task 3.3's compiler-side name-level
  backstop is marked done but is **absent**: `compile_oids/1`
  (`snmp_compiler.ex:578-583`) has no name-level `uniq_by`, and the compiler's
  only two `uniq_by` calls are by `uid` (:315) and by OID string (:363).
  Un-namespaced names would also collide with metric names core hardcodes for
  its own panels, and `metric_name` is both SRQL's `default_filter_field` and
  `default_series_field` (`srql/catalog.ex:1410-1432`) and a component of
  `series_key` (`timeseries_series_key.ex:45-55`), which participates in the row
  identity `[:timestamp, :gateway_id, :series_key]` (`timeseries_metric.ex:159-160`).
  C also would not fix 5b.1: the manifest would still hardcode a literal.

  **Why resolve at materialization, not at import.** `PluginPackage.alert_rules`
  is stored once and never rewritten, whereas `SNMPOIDTemplate.oids` *is*
  rewritten on every re-sync (`@template_definition_fields` includes `:oids`).
  Freezing a resolved name at import would let a future change to the naming rule
  move the metric while leaving the frozen rule behind - reintroducing the exact
  silent breakage this task names.

  **Ordering is a non-issue.** Alert rules materialize *before* SNMP requirements
  (`packages.ex:115-118`), so a DB lookup of the created template cannot work -
  but a pure call to the naming module needs no row to exist.

### 5b implementation

- [ ] 5b.2 Extract the naming rule into `ServiceRadar.Plugins.SNMPOIDNaming`:
  `@max_oid_name_length`, `@max_oid_namespace_length`, `namespaced_oids/2`,
  `oid_namespace/1`, `namespaced_oid_name/2`, `disambiguate/2`, `slug/1`, and
  add `materialized_oid_names/1 :: %{declared_name => materialized_name}`.
  `materialized_oid_names/1` MUST derive its values by calling
  `namespaced_oids/2` - the same function that writes `SNMPOIDTemplate.oids`
  (`snmp_requirement_catalog.ex:125`) - and zipping, never by re-deriving the
  string, so it cannot drift through the truncation and disambiguation paths.
  **Copy, do not move, `normalize_map/1` and `map_get/2`** (or use the existing
  `MapUtils`): `SNMPRequirementCatalog` uses both outside the naming block, and a
  literal move breaks its compilation. Point the catalog at the new module.
  Leave `qualified_name/2` (:222) alone - it builds the template/profile *row*
  name and protects a different constraint.

- [ ] 5b.3 **Whitelist the keys inside `match`, not just `metric_name`.**
  `MetricCondition.metric_comparison/1` reads
  `condition["comparison"] || condition[:comparison] || "gt"`
  (`observability/stateful_alert_engine/metric_condition.ex:113-114`) and
  **nothing anywhere reads `"op"`** - verified. So a rule written
  `condition: {op: lt, ...}` silently evaluates *greater-than*. That is the same
  bug class 5b.1 exists to kill, one key over, so gating `metric_name` alone is
  not enough. Reject any key inside `match` outside the matcher's vocabulary,
  and any key inside `condition` outside `comparison`/`threshold`.

- [ ] 5b.4 **Enforce uniqueness on the MATERIALIZED name, manifest-wide and
  case-folded** - not on the declared name. `namespaced_oids/2` builds its `seen`
  MapSet fresh per call and is called once per requirement, so `disambiguate/2`
  only catches truncation collisions *within* one requirement. Two requirements
  can materialize two distinct declared names onto one 64-char name with nothing
  detecting it, which makes a bare reference ambiguous and would let
  `materialized_oid_names/1`'s `Map.new` silently keep only the last pair.
  Compute `materialized_oid_names/1` over the whole manifest in
  `validate_snmp_requirements` and error on any duplicate value.

- [ ] 5b.5 Resolve in `AlertRuleCatalog.sync_rule/3` via `resolve_match/2`.
  Walk the **whole** `match` map, not just `match["metric_name"]`, and return
  `{:error, {:misplaced_snmp_oid_reference, path}}` for any `snmp_oid` map found
  outside the two legal positions (the value of `match.metric_name`, or an
  element of a list there). Accept both string and atom keys - `normalize_rule/1`
  stringifies only top-level rule keys, so inner keys stay as YAML parsed them.
  Trim declared names and the reference value identically so the validator's key
  space and the resolver's are provably the same.

- [ ] 5b.6 **Resolve before the status change.** Approve is non-transactional and
  one-shot, so a new error class inside `sync_alert_rules` would leave a package
  permanently approved with partial materialization and no retry. Run a dry
  `resolve_match/2` pass over `package.alert_rules` as a precondition in
  `approve/3`, alongside `enforce_verification_policy/1` (`packages.ex:105`).

- [ ] 5b.7 Add the import-time validation: `validate_snmp_requirements` must run
  before `validate_alert_rules` in `from_map/1` so the declared names are in
  scope, mirroring the existing
  `IntegrationDescriptor.validate(fetch(map, :integrations), producer_schedules)`
  precedent (`manifest.ex:421`). Note that the create path prefers caller-supplied
  `attrs[:alert_rules]` over `manifest_struct.alert_rules`, so the resolver's
  error path is load-bearing rather than merely legacy-facing.

- [ ] 5b.8 **Required, not optional:** make `AlertRuleCatalog`'s row identity
  version-stable. `qualified_name/2` (:147) builds `plugin:#{package.name}:#{name}`
  from the *editable display name*, and `find_existing/3` filters on
  `plugin_package_id`. `PluginPackage` is unique on `(plugin_id, version)`, so a
  version bump is a new row with a new id: the update branch misses and the create
  branch collides. Key on `plugin_id` and look up by name alone, as
  `SNMPRequirementCatalog` already does. Add `disable_package_rules` so deleting a
  package does not orphan a row holding the unique name.

- [ ] 5b.9 Tests: a resolvable reference validates and materializes to the
  namespaced string; unknown name, misplaced reference, non-string value and
  `signal: log` each produce their specific error; a plain literal still passes
  through unchanged; two requirements whose names truncate to one materialized
  name are rejected; `snmp_requirement_catalog_test.exs` must pass unchanged.

## 6. Customer-repo follow-up (does not land in this repo)

- [x] 6.1 Add `snmp_requirements:` to `plugins/clearpass-policy-manager/
  plugin.yaml`, sourced from the verified OID map in
  `config/snmp-clearpass.example.json`. Landed in the customer
  plugin repository, verified by running the real file through
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
