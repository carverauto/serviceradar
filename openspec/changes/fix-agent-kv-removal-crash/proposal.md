# Change: Fix Agent KV Removal Crash and Cleanup Legacy Code

## Why
The serviceradar-agent is crashing in demo-staging with a fatal error: `CONFIG_SOURCE=kv is no longer supported`. This is a casualty from the KV removal work in issue #2332. Additionally, issue #2331 reports confusing logs ("Checker request", "GatewayId is empty") that appear to be phantom polling but are actually expected internal behavior with overly noisy logging.

## Root Cause Analysis

### Issue 1: Agent Crash (Primary - Blocking)
- **Root Cause**: The agent deployment has `CONFIG_SOURCE=kv` environment variable set
- **Impact**: Agent pod is in CrashLoopBackOff, unable to load any configs
- **Code Path**: `pkg/config/config.go:241` returns `errKVConfigRemoved` when `CONFIG_SOURCE=kv`
- **Fix Status**: Code fix exists in commit `7b21d33af` (sets `CONFIG_SOURCE=file`), but ArgoCD hasn't synced demo-staging
- **Resolution**: Force ArgoCD sync to deploy the fix

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

1. **pkg/agent/server.go** - Fix noisy logging:
   - Line 538: Remove or downgrade "GatewayId is empty" warning (internal calls are expected)
   - Line 1122: Downgrade "Checker request" from INFO to DEBUG

2. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex**:
   - Remove `ServiceRadarAgentGateway.AgentClient` from supervisor children (line 140)
   - Remove `ServiceRadarAgentGateway.TaskExecutor` from supervisor children (line 143)

3. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_client.ex**:
   - Add deprecation notice to module doc
   - Keep file for reference (can be deleted in future cleanup)

4. **elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/task_executor.ex**:
   - Add deprecation notice to module doc
   - Keep file for reference (can be deleted in future cleanup)

### Deployment Changes

1. Verify ArgoCD demo-staging syncs to latest staging branch
2. Confirm agent restarts without crash
3. Validate push loop works correctly

## Impact
- Affected specs: `agent-configuration`
- Breaking changes: None (removing unused code)
- Risk: Low (AgentClient and TaskExecutor have no active callers)
