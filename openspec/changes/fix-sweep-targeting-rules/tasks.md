# Tasks: Fix Sweep Targeting Rules

## 1. Investigation & Diagnosis

- [x] 1.1 Add debug logging to `save_group` handler to log `rules_to_criteria` output
- [x] 1.2 Add debug logging to `criteria_to_rules` to log input criteria and output rules
- [x] 1.3 Add debug logging to `apply_action(:edit_group)` to log loaded target_criteria
- [x] 1.4 Add logging in `SweepCompiler.compile()` to trace group loading
- [x] 1.5 Add logging in `AgentConfigGenerator.load_sweep_config()` to trace config retrieval
- [ ] 1.6 Verify agent-gateway RPC calls reach core-elx with correct agent_id (needs runtime testing)

## 2. Fix Targeting Rules Persistence (UI)

- [x] 2.1 Improve `criteria_to_rules` to handle edge cases:
  - Added handling for single-operator specs (map_size == 1)
  - Added handling for multi-operator specs (map_size > 1)
  - Added warning logging for unexpected formats
- [x] 2.2 Add unit tests for `rules_to_criteria` / `criteria_to_rules` round-trip
  - Created `networks_live_criteria_test.exs` with comprehensive round-trip tests
- [ ] 2.3 Add form validation error display for invalid targeting criteria
- [ ] 2.4 Add visual feedback when targeting criteria are saved (show criteria count)

## 3. Fix Agent Config Generation

- [x] 3.1 Resolve partition from AgentRegistry instead of hardcoding "default"
  - Added `get_agent_partition/1` helper function
  - Updated `load_sweep_config/1` to use resolved partition
  - Updated `load_sysmon_config/1` to use resolved partition
- [x] 3.2 Add fallback to "default" partition if agent not registered
- [x] 3.3 Verify `for_agent_partition` filter logic handles all expected cases (via code review)
- [x] 3.4 Add integration test for sweep config compilation with targeting criteria
  - Created `sweep_targeting_integration_test.exs` with comprehensive SweepCompiler tests
  - Created partition resolution tests in `agent_config_generator_test.exs`
- [ ] 3.5 Verify cache invalidation triggers on sweep group update (needs runtime testing)

## 4. Improve Debugging & Observability

- [x] 4.1 Add debug logging throughout the sweep config flow:
  - UI save_group handler: logs criteria_rules, target_criteria, params, and result
  - UI edit_group handler: logs loaded target_criteria and converted rules
  - SweepCompiler: logs partition, agent_id, loaded groups, and their criteria
  - AgentConfigGenerator: logs partition resolution, config loading, and group counts
- [ ] 4.2 Add telemetry events for sweep config compilation
- [ ] 4.3 Add config compilation metrics (groups loaded, targets resolved, compilation time)
- [ ] 4.4 Add admin UI to view compiled sweep config for an agent

## 5. Testing & Validation

- [x] 5.1 Test: Create sweep group with CIDR targeting, verify rules persist on edit
  - Covered by `networks_live_criteria_test.exs` and `sweep_targeting_integration_test.exs`
- [x] 5.2 Test: Create sweep group with tag targeting (has_any), verify persistence
  - Covered by `networks_live_criteria_test.exs` and `sweep_targeting_integration_test.exs`
- [x] 5.3 Test: Create sweep group with multiple criteria fields, verify all persist
  - Covered by `networks_live_criteria_test.exs`
- [ ] 5.4 Test: Agent in k8s receives sweep config after group creation (needs runtime testing)
- [ ] 5.5 Test: Agent receives updated config after sweep group modification (needs runtime testing)
- [ ] 5.6 Test: Sweep execution triggers with correct targets from criteria (needs runtime testing)

## 6. Documentation

- [ ] 6.1 Document supported targeting operators in UI help text
- [ ] 6.2 Add troubleshooting guide for sweep config issues

## Summary of Changes Made

### Files Modified:

1. **web-ng/.../networks_live/index.ex**
   - Added debug logging to `save_group` handler (lines 323-336)
   - Added debug logging to `apply_action(:edit_group)` (lines 175-182)
   - Improved `criteria_to_rules` to handle edge cases and log parsing (lines 2350-2393)

2. **elixir/.../agent_config/compilers/sweep_compiler.ex**
   - Added debug logging to `load_sweep_groups` (lines 132-146)

3. **elixir/.../edge/agent_config_generator.ex**
   - Added `AgentRegistry` alias (line 37)
   - Added `get_agent_partition/1` helper function to resolve partition from registry (lines 329-352)
   - Updated `load_sweep_config/1` to use resolved partition (lines 295-327)
   - Updated `load_sysmon_config/1` to use resolved partition (lines 354-376)

### Test Files Created:

4. **web-ng/.../live/settings/networks_live_criteria_test.exs** (NEW)
   - Tests for targeting rules round-trip persistence (CIDR, tags, hostname, multiple criteria)
   - Tests for criteria validation (invalid operators, multiple operators per field, invalid CIDR)
   - Tests for criteria combined with static_targets

5. **elixir/.../sweep_jobs/sweep_targeting_integration_test.exs** (NEW)
   - Integration tests for targeting criteria persistence through database
   - Tests for SweepCompiler with CIDR and tag criteria matching devices
   - Tests for partition-based filtering
   - Tests for agent-specific sweep groups
   - Tests for config change detection

6. **elixir/.../edge/agent_config_generator_test.exs** (UPDATED)
   - Added "sweep config with partition resolution" describe block
   - Tests for unregistered agent defaulting to "default" partition
   - Tests for registered agent receiving sweep config from its partition
   - Tests for sweep groups with resolved targeting criteria
   - Tests for version changes when criteria updated
   - Tests for agent-specific sweep groups
