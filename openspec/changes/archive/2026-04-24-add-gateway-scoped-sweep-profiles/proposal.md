# Proposal: Gateway-Scoped Sweep Profiles

## Problem Statement

Currently, sweep groups can only be scoped to a `partition` and optionally a specific `agent_id`. However, in multi-gateway environments where different gateways have different network visibility, users need the ability to tie sweep groups to a specific gateway. This ensures that only agents connected to that gateway receive the sweep configuration.

**User Impact:**
- Without gateway scoping, all agents in a partition receive the same sweep config
- This causes issues when gateways have different network access
- Multiple agents may redundantly scan the same networks
- Users cannot control which gateway's agents perform which sweeps

## Proposed Solution

Add `gateway_id` as an optional field on `SweepGroup` that filters sweep config distribution:

1. **SweepGroup Resource**: Add `gateway_id` attribute (nullable string, references gateway UID)
2. **Sweep Compiler**: Update filtering to include gateway_id when present
3. **Agent Config Generator**: Resolve agent's gateway_id and pass it to sweep compiler
4. **Sweep Group UI**: Add gateway selector dropdown in the sweep group editor

### Data Flow (Updated)

```
Agent connects to Gateway
  → Agent has gateway_id set in Agent resource
  → Agent requests config from Gateway
  → Gateway calls AgentConfigGenerator.generate_config(agent_id)
    → AgentConfigGenerator resolves agent's gateway_id
    → ConfigServer.get_config(:sweep, partition, agent_id, gateway_id: gateway_id)
      → SweepCompiler.compile(partition, agent_id, gateway_id: gateway_id)
        → SweepGroup query filters: partition AND (agent_id OR nil) AND (gateway_id OR nil)
```

### Filtering Logic

When loading sweep groups for an agent:
- `partition` must match (required)
- `agent_id` must match OR be nil (agent-specific or partition-wide)
- `gateway_id` must match OR be nil (gateway-specific or all gateways)

This means:
- `gateway_id: nil` → sweep group applies to all gateways in the partition
- `gateway_id: "gw-123"` → sweep group only sent to agents connected to gateway gw-123

## Alternatives Considered

1. **Use partition as gateway proxy**: Not viable - partitions are logical groupings, gateways are physical/network boundaries
2. **Create agent-to-gateway mapping via tags**: Too complex and error-prone
3. **Filter at agent level**: Would require agents to know about gateway scoping logic

## Implementation Scope

- **Backend**: SweepGroup resource, sweep compiler, agent config generator
- **Frontend**: Sweep group editor form with gateway dropdown
- **Migration**: Add nullable `gateway_id` column to `sweep_groups` table

## Success Criteria

1. Users can create sweep groups scoped to a specific gateway
2. Agents only receive sweep configs for groups matching their gateway (or with no gateway set)
3. Existing sweep groups (gateway_id = nil) continue working for all gateways
4. UI shows gateway selection in sweep group editor at `/settings/networks/groups/:id/edit`
