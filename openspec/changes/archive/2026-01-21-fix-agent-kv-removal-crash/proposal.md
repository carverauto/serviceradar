# Change: Fix Agent KV Removal Crash and Cleanup Legacy Code

## Why
The serviceradar-agent is crashing in demo-staging with a fatal error: `CONFIG_SOURCE=kv is no longer supported`. This is a casualty from the KV removal work in issue #2332. Additionally, issue #2331 reports confusing logs ("Checker request", "GatewayId is empty") that appear to be phantom polling but are actually expected internal behavior with overly noisy logging.

## Root Cause Analysis

### Issue 1: Agent Crash (Primary - Blocking)
- **Root Cause**: The agent deployment has `CONFIG_SOURCE=kv` environment variable set
- **Impact**: Agent pod is in CrashLoopBackOff, unable to load any configs
- **Code Path**: `pkg/config/config.go:241` returned `errKVConfigRemoved` when `CONFIG_SOURCE=kv`
- **Resolution**: Made CONFIG_SOURCE=kv idempotent - logs deprecation warning and falls back to file config instead of crashing

### Issue 2: "Checker request" Logs (Not a Bug - Just Noise)
- **Root Cause**: The agent's push loop calls `server.GetStatus()` internally to collect checker statuses before pushing to gateway (`push_loop.go:638`)
- **Impact**: These INFO-level logs appear confusing but are expected behavior
- **Resolution**: Downgrade "Checker request" log from INFO to DEBUG level

### Issue 3: "GatewayId is empty in request" Warnings (Not a Bug - Just Noise)
- **Root Cause**: Internal calls from push loop don't set GatewayId (`push_loop.go:631-635`)
- **Impact**: Warning logs spam for expected internal behavior (`server.go:538`)
- **Resolution**: Remove warning or detect internal vs external calls

### Issue 4: Legacy Polling Code in Gateway (Technical Debt)
- **Finding**: `ServiceRadarAgentGateway.AgentClient` and `ServiceRadarAgentGateway.TaskExecutor` are legacy modules still started in the gateway supervisor
- **Current State**: These modules are dormant (no active connections/tasks) but represent dead code
- **Impact**: Confusing codebase, potential for accidental activation
- **Resolution**: Remove from supervisor tree and deprecate modules

## What Changes

### Code Changes

1. **pkg/config/config.go** - Make CONFIG_SOURCE=kv idempotent:
   - Changed from returning fatal error to logging warning and using file config
   - Removed unused `errKVConfigRemoved` error variable

2. **pkg/agent/server.go** - Fix noisy logging:
   - Line 538: Remove or downgrade "GatewayId is empty" warning (internal calls are expected)
   - Line 1122: Downgrade "Checker request" from INFO to DEBUG

3. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex**:
   - Remove `ServiceRadarAgentGateway.AgentClient` from supervisor children
   - Remove `ServiceRadarAgentGateway.TaskExecutor` from supervisor children

4. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_client.ex**:
   - Delete entirely (legacy polling code, no longer needed)

5. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/task_executor.ex**:
   - Delete entirely (legacy polling code, no longer needed)

### Deployment Changes

1. Remove serviceradar-snmp-checker deployment from demo-staging (functionality now in agent)
2. Confirm agent restarts without crash
3. Validate push loop works correctly

## Impact
- Affected specs: `agent-configuration`
- Breaking changes: None (removing unused code)
- Risk: Low (AgentClient and TaskExecutor have no active callers)
