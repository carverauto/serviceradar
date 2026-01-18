## 1. Immediate Fix - Agent Crash (Blocking)
- [ ] 1.1 Verify ArgoCD demo-staging app has synced to latest staging branch (commit 7b21d33af or later)
- [ ] 1.2 If not synced, trigger ArgoCD refresh/sync: `argocd app sync serviceradar-demo-staging`
- [ ] 1.3 Verify serviceradar-agent pod restarts successfully without crash
- [ ] 1.4 Confirm `CONFIG_SOURCE=file` in running agent: `kubectl get deployment serviceradar-agent -n demo-staging -o yaml | grep CONFIG_SOURCE`

## 2. Fix Noisy Logging in Go Agent
- [x] 2.1 In `pkg/agent/server.go:538`, remove the "GatewayId is empty in request" warning (internal calls are expected)
- [x] 2.2 In `pkg/agent/server.go:1122`, change "Checker request" log from Info to Debug level
- [x] 2.3 Run `go test ./pkg/agent/...` to verify no regressions

## 3. Remove Legacy Polling Code from Gateway
- [x] 3.1 In `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex`:
  - Remove `ServiceRadarAgentGateway.AgentClient` from supervisor children
  - Remove `ServiceRadarAgentGateway.TaskExecutor` from supervisor children
- [x] 3.2 Add deprecation notice to `agent_client.ex` module doc
- [x] 3.3 Add similar deprecation notice to `task_executor.ex`
- [x] 3.4 Verify gateway compiles successfully

## 4. Validation
- [ ] 4.1 Deploy changes to demo-staging
- [ ] 4.2 Verify agent logs no longer show "Checker request" at INFO level
- [ ] 4.3 Verify agent logs no longer show "GatewayId is empty in request" warnings
- [ ] 4.4 Verify agent push loop works correctly (status pushed to gateway)
- [ ] 4.5 Verify gateway logs show clean startup without AgentClient/TaskExecutor

## 5. Documentation
- [ ] 5.1 Close GitHub issue #2331 with explanation that logs were expected internal behavior, now fixed
- [ ] 5.2 Update issue #2332 with completion notes about demo-staging sync
