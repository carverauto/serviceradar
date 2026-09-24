## 1. Core: assignments and target policies

- [ ] 1.1 Key `NoDuplicateEnabledAssignment` by (partition, agent, plugin,
      provisioning source key); fixed key for manual/producer-schedule rows,
      policy assignment key for target-policy rows. Tests for coexistence and
      same-source rejection.
- [ ] 1.2 Restrict the policy reconciler's adopt path to rows with the same
      source key. Tests for adopt vs create.
- [ ] 1.3 Add `fields` to target-policy input definitions: validate path forms
      in `SRQLInputResolver` and the materializer's input definitions, carry
      them through `chunk_input_descriptor`, copy them in
      `normalize_device_row`. Tests for projection, rejection, size limits.
- [ ] 1.4 Expose `interval_seconds` as a target-policy rule control (60..86400)
      and use it when planning. Test.

## 2. Core: result handler

- [ ] 2.1 Add `NetworkConfig.InterfaceCheckIngestor` for
      `serviceradar.interface_config_check.v1`: per device UID, atomic
      `merge_metadata` of `config_check.<check>`; skip and count unknown UIDs;
      never create devices. Register it in `platform_contract_handlers`.
- [ ] 2.2 Tests (database-free where possible; DB-backed merge test with the
      right INTEGRATION_SOURCE_DISPOSITIONS row).

## 3. Plugin: opentext-nom config check mode

- [ ] 3.1 Parse check configuration from the `plugin_inputs.v1` template;
      branch on the payload schema before `ParseConfig`.
- [ ] 3.2 Attachment resolution (map or `switch:port`) and shorthand expansion
      table with operator overrides.
- [ ] 3.3 `show configlet -host -start -end` via the wrapper; reuse the
      command client and result-envelope decoding.
- [ ] 3.4 Declarative check evaluation (literal/regex, all/any, case) and the
      `serviceradar.interface_config_check.v1` result; no config text in the
      result.
- [ ] 3.5 Manifest: second credential profile (`opentext-nom-config-check`,
      `target_policy`), config schema for checks, version bump.
- [ ] 3.6 Unit tests plus a native local-host test; live test against NA with a
      test interface description.

## 4. Docs and validation

- [ ] 4.1 Plugin README and `docs/configuration.md`: check configuration,
      examples for NAC and a description-presence test, shorthand table,
      delimiters per vendor.
- [ ] 4.2 `openspec validate add-interface-config-compliance-checks --strict`.
- [ ] 4.3 `make test` scope for touched packages; gate through no-mistakes.
