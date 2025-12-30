# Tasks: Add Coordinator Leader Election

## Phase 1: Core Infrastructure (Priority: High)

### 1.1 CoordinatorCandidate GenServer
- [ ] 1.1.1 Create `lib/serviceradar/cluster/coordinator_candidate.ex` module
- [ ] 1.1.2 Implement `:global.register_name/3` for leader election
- [ ] 1.1.3 Add periodic leader check (configurable interval, default 5s)
- [ ] 1.1.4 Implement leader monitoring with `:erlang.monitor/2`
- [ ] 1.1.5 Add takeover delay to prevent rapid leader flapping
- [ ] 1.1.6 Add telemetry events for election state changes

### 1.2 Coordinator GenServer
- [ ] 1.2.1 Create `lib/serviceradar/cluster/coordinator.ex` module
- [ ] 1.2.2 Implement global registration under `{:global, ServiceRadar.Cluster.Coordinator}`
- [ ] 1.2.3 Start coordination processes on becoming leader
- [ ] 1.2.4 Stop coordination processes on losing leadership
- [ ] 1.2.5 Add graceful shutdown with leader release

### 1.3 CoordinatorSupervisor
- [ ] 1.3.1 Create `lib/serviceradar/cluster/coordinator_supervisor.ex`
- [ ] 1.3.2 Supervise ClusterHealth, PollOrchestrator under coordinator
- [ ] 1.3.3 Configure `:one_for_one` strategy with restart limits
- [ ] 1.3.4 Add child spec for dynamic start/stop

## Phase 2: Configuration (Priority: High)

### 2.1 Environment Configuration
- [ ] 2.1.1 Add `COORDINATOR_ELIGIBLE` env var (default: based on node type)
- [ ] 2.1.2 Add `COORDINATOR_ELECTION_INTERVAL` env var (default: 5000ms)
- [ ] 2.1.3 Add `COORDINATOR_TAKEOVER_DELAY` env var (default: 1000ms)
- [ ] 2.1.4 Update `config/runtime.exs` with coordinator config
- [ ] 2.1.5 Document configuration in proposal

### 2.2 Node Type Detection
- [ ] 2.2.1 Create `ServiceRadar.Cluster.NodeType` module
- [ ] 2.2.2 Implement logic to determine if node can be coordinator
- [ ] 2.2.3 Default core-elx and web-ng as eligible, poller-elx as ineligible
- [ ] 2.2.4 Add override via environment variable

## Phase 3: Migration (Priority: High)

### 3.1 Remove Static Coordinator Assignment
- [ ] 3.1.1 Remove `cluster_coordinator: true/false` from config
- [ ] 3.1.2 Update Application.start to use CoordinatorCandidate
- [ ] 3.1.3 Remove direct ClusterSupervisor start from Application
- [ ] 3.1.4 Add CoordinatorCandidate to supervision tree

### 3.2 Update Existing Components
- [ ] 3.2.1 Update ClusterHealth to work under CoordinatorSupervisor
- [ ] 3.2.2 Update PollOrchestrator to work under CoordinatorSupervisor
- [ ] 3.2.3 Ensure coordination processes are stateless or use shared DB
- [ ] 3.2.4 Add process restart tolerance

## Phase 4: Observability (Priority: Medium)

### 4.1 Telemetry Events
- [ ] 4.1.1 Add `[:serviceradar, :coordinator, :election_started]` event
- [ ] 4.1.2 Add `[:serviceradar, :coordinator, :became_leader]` event
- [ ] 4.1.3 Add `[:serviceradar, :coordinator, :lost_leadership]` event
- [ ] 4.1.4 Add `[:serviceradar, :coordinator, :leader_changed]` event
- [ ] 4.1.5 Include node name and timestamp in all events

### 4.2 Logging
- [ ] 4.2.1 Add structured logging for leader election transitions
- [ ] 4.2.2 Log leader node name on election
- [ ] 4.2.3 Log takeover attempts and outcomes
- [ ] 4.2.4 Add debug logging for periodic checks

### 4.3 Health Endpoints
- [ ] 4.3.1 Add coordinator status to `/api/health` endpoint
- [ ] 4.3.2 Include current leader node in cluster status
- [ ] 4.3.3 Add leader election state to ClusterStatus

## Phase 5: Testing (Priority: High)

### 5.1 Unit Tests
- [ ] 5.1.1 Test CoordinatorCandidate state transitions
- [ ] 5.1.2 Test Coordinator startup/shutdown
- [ ] 5.1.3 Test configuration parsing
- [ ] 5.1.4 Test node eligibility logic

### 5.2 Integration Tests
- [ ] 5.2.1 Test leader election in multi-node cluster
- [ ] 5.2.2 Test failover when leader node stops
- [ ] 5.2.3 Test no split-brain with multiple candidates
- [ ] 5.2.4 Test graceful handoff during shutdown

### 5.3 Chaos Testing
- [ ] 5.3.1 Test leader crash recovery
- [ ] 5.3.2 Test network partition handling
- [ ] 5.3.3 Test rolling restart scenario
- [ ] 5.3.4 Verify coordination continues during failover

## Phase 6: Documentation (Priority: Low)

### 6.1 Update Documentation
- [ ] 6.1.1 Update cluster architecture docs
- [ ] 6.1.2 Document leader election behavior
- [ ] 6.1.3 Document configuration options
- [ ] 6.1.4 Add troubleshooting guide for election issues

### 6.2 Operational Runbooks
- [ ] 6.2.1 Document how to force leader change
- [ ] 6.2.2 Document how to debug election issues
- [ ] 6.2.3 Document monitoring alerts for leader changes

## Dependencies

- Phase 2 depends on Phase 1.1 (configuration used by candidate)
- Phase 3 depends on Phase 1 and 2 (migration requires new components)
- Phase 4 can run in parallel with Phase 3
- Phase 5 depends on Phase 3 completion
- Phase 6 runs after Phase 5

## Validation Checkpoints

1. **After Phase 1**: CoordinatorCandidate and Coordinator can be started manually
2. **After Phase 2**: Configuration loads correctly from environment
3. **After Phase 3**: Leader election works in docker-compose cluster
4. **After Phase 4**: Telemetry events visible, health endpoint updated
5. **After Phase 5**: All tests pass, chaos tests demonstrate resilience
6. **After Phase 6**: Documentation complete
