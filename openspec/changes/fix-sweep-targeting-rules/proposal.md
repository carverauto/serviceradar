# Change: Fix Sweep Group Targeting Rules Not Saved and Agent Config Generation

## Why

Sweep groups configured in the UI with targeting rules via the SRQL builder are not being saved correctly, and agents are not receiving sweep configurations. This breaks the network sweep functionality where agents should perform port scans/ICMP scans on hosts matching the targeting criteria.

## Problem Analysis

### Issue 1: Targeting Rules Not Persisting in UI

When a user:
1. Creates/edits a sweep group in Settings > Networks
2. Defines targeting rules using the SRQL builder (e.g., `ip in_cidr "10.0.0.0/8"`)
3. Saves the sweep group
4. Opens the sweep group for editing

The targeting rules are not displayed - the SRQL builder shows empty.

**Root Cause Investigation:**

The `criteria_to_rules` function (`web-ng/.../networks_live/index.ex:2321`) only handles single operator-value pairs per field:

```elixir
defp criteria_to_rules(criteria) when is_map(criteria) do
  Enum.flat_map(criteria, fn {field, operator_spec} ->
    case Map.to_list(operator_spec) do
      [{operator, value}] ->  # Only matches single operator
        [%{id: ..., field: field, operator: operator, value: ...}]
      _ ->
        []  # Returns empty if structure doesn't match!
    end
  end)
end
```

Potential issues:
- Database stores criteria differently than expected
- Multi-operator criteria (e.g., `has_any` + `has_all`) are dropped
- Empty criteria map `%{}` is being saved instead of actual criteria

### Issue 2: Agent Not Receiving Sweep Config

The agent requests config via agent-gateway RPC, which calls `AgentConfigGenerator.get_config_if_changed()`. The sweep config flow:

1. `AgentConfigGenerator.load_sweep_config(agent_id)` - line 294
2. `ConfigServer.get_config(:sweep, "default", agent_id)` - hardcoded partition
3. `SweepCompiler.compile("default", agent_id)` - compiles sweep groups
4. `SweepGroup.for_agent_partition(partition, agent_id)` - loads matching groups

**Potential Issues:**

1. **Partition Mismatch**: Partition is hardcoded to `"default"` in `AgentConfigGenerator`, but sweep groups may be configured with different partitions.

2. **Agent ID Filtering**: The `for_agent_partition` filter logic:
   ```elixir
   filter expr(
     enabled == true and
     partition == ^arg(:partition) and
     (is_nil(^arg(:agent_id)) or agent_id == ^arg(:agent_id) or is_nil(agent_id))
   )
   ```
   Groups only match if:
   - `enabled == true`
   - `partition` matches exactly
   - AND either no agent_id filter OR group's agent_id matches OR group's agent_id is nil

3. **Empty target_criteria**: If targeting rules aren't saved (Issue 1), `compile_targets()` returns only `static_targets` which may be empty.

4. **Config Cache TTL**: 5-minute cache TTL may delay config updates.

## What Changes

### Investigation & Debugging
- [ ] Add logging to trace targeting rules through save/load cycle
- [ ] Verify database values for `target_criteria` column after save
- [ ] Trace agent config request through agent-gateway to core-elx
- [ ] Verify partition value in sweep group matches expected value

### Fixes Required
- [ ] **Fix `criteria_to_rules` parsing** - Handle all operator structures correctly
- [ ] **Fix `rules_to_criteria` conversion** - Ensure proper format for database storage
- [ ] **Add validation feedback** - Show errors when targeting criteria fail validation
- [ ] **Partition handling** - Support partition resolution from agent registration
- [ ] **Improve cache invalidation** - Ensure config changes propagate promptly
- [ ] **Add debug logging** - Trace sweep config compilation for troubleshooting

### Testing
- [ ] Verify targeting rules persist through save/edit cycle
- [ ] Verify agent receives sweep config with correct targets
- [ ] Test with various targeting operators (in_cidr, has_any, eq, etc.)

## Impact

- Affected specs: `sweep-jobs`, `agent-config`
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex` - SRQL builder
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex` - config loading
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex` - compilation
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_group.ex` - Ash resource
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/target_criteria.ex` - criteria validation
