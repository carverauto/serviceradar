# Change: Fix config compilers executing on agent-gateway

## Why

Config compilers (SweepCompiler, etc.) are executing on agent-gateway nodes instead of core-elx nodes. This causes database queries to fail because the agent-gateway has **zero database access**.

The error from issue #2572:
```
SweepCompiler: SRQL query failed - relation "ocsf_devices" does not exist
```

**Root cause**: The `core_nodes()` function in `AgentGatewayServer` includes the gateway itself in the list of eligible RPC targets. When it can't find a node running `ServiceRadar.ClusterHealth`, it falls back to checking for `ServiceRadar.Repo`. Since the gateway application starts `ServiceRadar.Repo` by default (line 218-227 of `application.ex`), the gateway gets selected for the RPC call, causing the code to execute locally on a node with no database.

This violates the architecture: **agent-gateway should be passive and NEVER execute database-dependent logic**.

Reference: GitHub issue #2572

## What Changes

1. **Remove Repo startup from agent-gateway** - The gateway has no database access and should not start `ServiceRadar.Repo`. This eliminates the gateway from the Repo-based fallback in `core_nodes()`.

2. **Improve core node detection** - The `core_nodes()` function should explicitly exclude gateway nodes and require `ClusterHealth` (coordinator process) rather than falling back to any node with Repo.

3. **Fail clearly when no core available** - If no core-elx node is available for config compilation, return a clear error instead of attempting local execution.

## Impact

- Affected specs: `edge-architecture`
- Affected code:
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex` - Remove `repo_child()` from children
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_gateway_server.ex` - Improve `core_nodes()` to never include self for DB-dependent operations
