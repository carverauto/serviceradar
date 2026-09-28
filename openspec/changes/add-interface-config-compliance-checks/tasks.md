## 1. Core: assignment ownership

- [x] 1.1 `AssignmentOwner`: derive the owner from `policy_id`; different
      credential rules may coexist, manual rows and other policies keep the
      single-assignment rule. Used by `NoDuplicateEnabledAssignment`.
- [x] 1.2 Policy reconciler adopts only an assignment of the same owner.
- [x] 1.3 Tests: ownership rules, drift adoption preserved, no cross-rule
      adoption.

## 2. Core: schedule target items

- [x] 2.1 Manifest: producer schedule `target_input` (entity, query_param,
      fields_param, max_items), validated and carried into the contract.
- [x] 2.2 `SRQLInputResolver`: validated projected `fields` (device column or
      `metadata.<key>`, never whole `metadata`); `PluginInputPayloadBuilder`
      copies them under `fields`.
- [x] 2.3 `ProducerScheduleDispatcher.resolve_target_items/2`: resolve the
      configured query once per dispatch and add `target_items` to each run.
- [x] 2.4 Tests for manifest validation, field projection and target items.

## 3. Core: result handler

- [x] 3.1 `NetworkConfig.InterfaceCheckIngestor` for
      `serviceradar.interface_config_check.v1`: `config_check_<check>` status
      and `_detail` via atomic `merge_metadata`; unknown UIDs skipped; only
      `config_check_*` keys written. Registered in `platform_contract_handlers`.
- [x] 3.2 Database-free tests with an injected device store.

## 4. Plugin: opentext-nom interface check

- [x] 4.1 Check definition, attachment resolution, shorthand expansion,
      `show configlet -host -start -end`, declarative evaluation, verdict
      reasons, per-run memoization, auth failures abort the run.
- [x] 4.2 Producer schedule run path (`opentext-nom.interface.check`,
      `target_items`); inventory and retrieve ignore check-only config keys.
- [x] 4.3 Manifest: second producer schedule with `target_input` and a second
      credential profile (`opentext-nom-config-check`); config schema entries;
      version bump.
- [x] 4.4 Unit tests; live verification against NA with an ArubaOS-Switch and a
      Cisco IOS switch.

## 5. UI, docs and validation

- [x] 5.1 Plugin config form: `x-serviceradar-ui-control: textarea` for string
      fields, with a test.
- [x] 5.2 Plugin README and `docs/configuration.md`: configuration, examples,
      delimiters per vendor, shorthand table, querying results.
- [x] 5.3 `openspec validate add-interface-config-compliance-checks --strict`.
- [ ] 5.4 Gate through no-mistakes (review, test, CI).
