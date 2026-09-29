## 1. Audit and pinning (before any compiler change)

- [ ] 1.1 Confirm whether any production path writes `config_type = 'sweep'`
      rows into `platform.agent_config_instances`. If none does, open a
      separate issue: the `device_sweep_overlap` view's declared arm is empty
      in production. Record the finding in design.md, Decision 7.
      (Confirmed none does and recorded in Decision 7; the issue is not yet
      filed.)
- [x] 1.2 Add a pinning test (landed as the database-free
      `test/serviceradar/agent_config/compilers/sweep_compiler_targets_test.exs`
      over `SweepCompiler.compile_groups/3`, with an injected SRQL page
      function) that compiles a fixed set of groups (static targets, one query shared by
      two groups, one distinct query) and asserts the full current legacy
      output and its `config_hash`. Land it first; later tasks update it
      deliberately, never incidentally.
- [x] 1.3 Add a Go parity test that device-target metadata beyond
      `device_uid` does not change the scan targets the sweeper generates
      (landed in `go/pkg/sweeper/target_count_test.go`). Sweep results carry
      no target metadata, so target generation is the observable surface.
      Tasks 2.3 and 4.4 reuse it to prove parity.

## 2. Core, legacy format only

- [x] 2.1 In `SweepCompiler.compile/3`, normalize each group's
      `target_query` and execute each distinct query once per compile. Build
      legacy `device_targets` from the shared rows. The 1.2 test must stay
      green without edits.
- [x] 2.2 Emit compiled `groups` sorted by `id`. Test that shuffled group and
      row order yields the same `config_hash` and config version. If the
      legacy config version was order-dependent before this task, note it in
      the PR as a fixed source of spurious config pushes.
- [x] 2.3 Trim `sweep_group_id`, `target_query`, `hostname` and
      `discovery_sources` from per-target metadata, keeping `device_uid`.
      Update the 1.2 expectation in the same commit, and show the 1.3
      results test unchanged.
- [x] 2.4 Add the cross-agent query result cache (Decision 2): key
      `{:sweep_query, normalized_query}`, configurable TTL defaulting to 60
      seconds (see design.md, Decision 2), storing only `ip` and `uid`, never
      caching failures. Entries live under the `:sweep` config type, so the
      existing SweepGroup/SweepProfile catalog dispatch drops them.
- [x] 2.5 Tests: equal queries across groups run once per compile and once
      across two agents' compiles within the TTL (count executions through an
      injectable query runner); editing a group's query changes the next
      compile; a raising shared query leaves only its groups empty and is not
      cached. If any of these are database-backed core integration tests,
      bump the selected-count in the corresponding `.bzl` target. (All landed
      as database-free unit tests, so no count changes.)

## 3. Core shared-targets format

- [ ] 3.1 Add a `format` option to `SweepCompiler.compile/3` (`:legacy`
      default, `:shared_targets_v1`) that emits `device_table`,
      `target_sets`, and per-group `device_target_set`, as specified in
      design.md Decision 3.
- [ ] 3.2 Compute the shared-targets `config_hash` over the sorted `groups`,
      `device_table` and `target_sets` (Decision 6).
- [ ] 3.3 Tests: the three-profiles-over-one-query scenario (one table entry
      per device, one set, three groups); partial overlap; determinism under
      shuffled rows (no shared IPs); two devices sharing an IP under
      different queries stay two table entries with their own `device_uid`.
- [ ] 3.4 Add a `device_sweep_overlap` view arm for `shared-targets/v1`
      (Decision 7) in a new migration, with a test that the same groups
      persisted in each format yield the same declared rows. Bump the Helm
      `expectedVersion` for the new migration.

## 4. Go agent

- [ ] 4.1 In `go/pkg/agent/sweep_config_gateway.go`, add the shared-targets
      types and dispatch `parseGatewaySweepConfig/2` on `format`. Absent
      means legacy, `shared-targets/v1` means rehydrate (Decision 5), and
      anything else is an error that keeps the current sweep config.
- [ ] 4.2 Make the unknown-format error path in `applySweepConfig` keep the
      running config instead of clearing targets. Test it by applying a valid
      config, then an unknown-format one, and asserting the service's groups
      are unchanged.
- [ ] 4.3 Advertise `sweep-config-shared-targets:v1` from
      `agentCapabilities/1`, and add it to the capability test expectations.
- [ ] 4.4 Parity tests: equivalent legacy and shared-targets payloads parse
      to equal `SweepGroupsConfig` values, and the 1.3 results test reports
      the same envelope for both.

## 5. Core format selection

- [ ] 5.1 In `AgentConfigGenerator.load_sweep_config/2`, resolve the agent's
      persisted capabilities (the same lookup as
      `resolve_agent_addon_profile/2`) and pass `sweep_format` to
      `ConfigServer.get_config/4`.
- [ ] 5.2 Add a `cache_scope(:sweep, opts)` clause returning
      `{:sweep_format, format}`.
- [ ] 5.3 Tests through `AgentConfigGenerator.get_config_if_changed/3`: a
      legacy-capability agent gets no `format` key and embedded
      `device_targets`; a capable agent gets `shared-targets/v1`; two agents
      in one partition get their own formats; after a capability change the
      next request returns a new version in the new format.

## 6. Generation cost (measure first, fix only what shows up)

- [ ] 6.1 Measure where sweep config generation time goes for a synthetic
      config with many overlapping groups: SRQL paging, target building,
      `stable_config_fragment` hashing in `agent_config_generator.ex`, and the
      `Jason.encode!` of `config_json`, which currently runs before the
      version comparison, so a `not_modified` poll still pays for the full
      encode.
- [ ] 6.2 Check whether the gateway decodes the full `config_json` only to log
      its size (`agent_gateway_server.ex`, config summary logging), and if so
      compute the size without decoding.
- [ ] 6.3 File follow-ups for anything that 6.1 shows and this change does not
      remove, including SNMP targets repeating OID lists per device and plugin
      params sent twice.

## 7. Rollout and verification

- [ ] 7.1 Release order: section 2 after chunked config pushes have shipped;
      then the agent release (section 4); then sections 3.4 and 5. Document
      the order in the release notes.
- [ ] 7.2 Log the sweep section format and encoded size per agent at config
      generation, so the reduction can be checked against a deployment.
- [ ] 7.3 Verify on a staging deployment with synthetic groups. Confirm that
      the legacy sweep section shrinks after section 2, that a capable
      agent's section shrinks further after section 5, that compile time
      drops for overlapping groups, and that sweep results are unchanged.
      Gate each check on data produced after the rollout finished.
- [ ] 7.4 Run `openspec validate refactor-sweep-config-shared-targets --strict`.
