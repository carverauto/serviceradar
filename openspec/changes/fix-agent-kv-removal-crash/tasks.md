## 1. Immediate Fix - Agent Crash (Blocking)
- [x] 1.1 Made CONFIG_SOURCE=kv idempotent (logs warning, falls back to file instead of crashing)
- [x] 1.2 Manually set CONFIG_SOURCE=file on demo-staging deployment
- [x] 1.3 Verified serviceradar-agent pod restarts successfully without crash
- [x] 1.4 Removed serviceradar-snmp-checker deployment and service from demo-staging (functionality baked into agent)

## 2. Fix Noisy Logging in Go Agent
- [x] 2.1 In `pkg/agent/server.go:538`, remove the "GatewayId is empty in request" warning (internal calls are expected)
- [x] 2.2 In `pkg/agent/server.go:1122`, change "Checker request" log from Info to Debug level
- [x] 2.3 Run `go test ./pkg/agent/...` to verify no regressions

## 3. Remove Legacy Polling Code from Gateway
- [x] 3.1 In `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex`:
  - Remove `ServiceRadarAgentGateway.AgentClient` from supervisor children
  - Remove `ServiceRadarAgentGateway.TaskExecutor` from supervisor children
- [x] 3.2 Delete `agent_client.ex` module entirely (not just deprecate)
- [x] 3.3 Delete `task_executor.ex` module entirely (not just deprecate)
- [x] 3.4 Verify gateway compiles successfully

## 4. Validation
- [x] 4.1 Agent running in demo-staging without crash
- [ ] 4.2 Verify agent logs no longer show "Checker request" at INFO level
- [ ] 4.3 Verify agent logs no longer show "GatewayId is empty in request" warnings
- [ ] 4.4 Verify agent push loop works correctly (status pushed to gateway)
- [ ] 4.5 Verify gateway logs show clean startup without AgentClient/TaskExecutor

## 5. Documentation
- [ ] 5.1 Close GitHub issue #2331 with explanation that logs were expected internal behavior, now fixed
- [ ] 5.2 Update issue #2332 with completion notes about demo-staging sync
