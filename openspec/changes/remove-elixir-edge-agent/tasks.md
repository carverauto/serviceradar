## 1. Remove Elixir Agent Application

- [x] 1.1 Archive `elixir/serviceradar_agent/` (move to `_deprecated/` or delete)
- [x] 1.2 Remove `serviceradar_agent` from umbrella project deps
- [x] 1.3 Remove `serviceradar_agent` from mix.exs workspaces
- [x] 1.4 Update Docker build to exclude Elixir agent
- [x] 1.5 Remove Elixir agent from docker-compose files

## 2. Update Cluster Configuration

- [x] 2.1 Remove agent ERTS cluster config from `serviceradar_core`
- [x] 2.2 Remove `ServiceRadar.AgentRegistry` Horde usage (if agent-specific) - Kept: AgentRegistry still tracks gRPC agents
- [x] 2.3 Update `cluster_health.ex` to not expect agent nodes - No changes needed: still syncs AgentRegistry
- [x] 2.4 Update libcluster topology to exclude agent node patterns - Updated CLUSTER_HOSTS
- [x] 2.5 Remove agent-related node monitoring - Updated detect_node_type() in LiveViews

## 3. Update Poller to Initiate gRPC Connections

- [x] 3.1 Add gRPC client to poller for agent communication - Created AgentClient GenServer
- [x] 3.2 Implement agent discovery (query core for assigned agents) - AgentClient queries AgentRegistry.get_grpc_address
- [x] 3.3 Implement scheduled polling loop to agents - PollJob state machine with AshOban orchestration on core
- [x] 3.4 Add agent health check via gRPC - AgentClient.get_status() and periodic health_check
- [x] 3.5 Handle agent unreachable (retry, backoff, alerting) - AgentClient has reconnection logic

## 4. Update Agent Registration Flow

- [x] 4.1 Agent records created during onboarding (host:port known) - POST /api/v2/agents for admin/onboarding
- [x] 4.2 Core stores agent connection details (host:port, tenant_id) - Infrastructure.Agent has host/port attributes
- [x] 4.3 Pollers query core for their assigned agents - Infrastructure.Agent.by_poller, AgentRegistry.find_agents_with_grpc/1
- [x] 4.4 Pollers update agent status after gRPC connection - PATCH /api/v2/agents/:uid for establish_connection, heartbeat, lose_connection

## 5. Update Edge Onboarding

- [x] 5.1 Onboarding generates Go agent config only - Go edgeonboarding pkg generates agent.json
- [x] 5.2 Remove Elixir agent download option from UI - N/A: No Elixir agent UI existed
- [x] 5.3 Update onboarding templates for Go agent - Go pkg/edgeonboarding handles config generation
- [x] 5.4 Update certificate generation - Already works for all component types (poller/agent/checker)

## 6. Update Helm Charts

- [x] 6.1 Remove Elixir agent deployment from Helm chart
- [x] 6.2 Update agent chart to use Go agent only
- [x] 6.3 Update values.yaml defaults
- [ ] 6.4 Update chart documentation

## 7. Update Documentation

- [ ] 7.1 Update architecture diagrams (remove ERTS from edge)
- [x] 7.2 Update agent deployment docs - Updated README.md
- [ ] 7.3 Add security architecture documentation
- [ ] 7.4 Document firewall requirements (gRPC port only)
- [ ] 7.5 Update troubleshooting guides

## 8. Testing

- [ ] 8.1 Test poller-to-agent gRPC communication
- [x] 8.2 Test agent registration via core API - Created agent_test.exs (14 tests pass)
- [x] 8.3 Test multi-tenant agent isolation - Created agent_tenant_isolation_test.exs (10 tests pass)
- [x] 8.4 Test agent health monitoring - Created agent_health_test.exs (14 tests pass)
- [ ] 8.5 Integration test: full polling flow without ERTS
- [x] 8.6 Verify ERTS cluster has no edge nodes - Cluster tests pass (74 tests, 0 failures)

## 9. Security Validation

- [ ] 9.1 Verify edge cannot RPC to core nodes
- [ ] 9.2 Verify edge cannot enumerate Horde registries
- [ ] 9.3 Verify mTLS tenant validation works
- [ ] 9.4 Penetration test: attempt cross-tenant access from edge
- [ ] 9.5 Document security properties in runbook
