# Add Coordinator Leader Election for Cluster Resilience

## Summary

Implement dynamic leader election for the cluster coordinator role, allowing any eligible node (core-elx or web-ng) to assume coordination responsibilities. This eliminates core-elx as a single point of failure and enables automatic failover during node restarts or crashes.

## Motivation

### Current Problem

The cluster coordinator role is statically assigned to core-elx via `cluster_coordinator: true`. If core-elx goes down:

- **ClusterHealth monitoring stops** - No health telemetry emitted
- **PollOrchestrator stops** - No new polls scheduled
- **No graceful degradation** - web-ng can serve UI but with stale coordination data

This is problematic during:
- core-elx restarts/deploys
- Unexpected crashes
- Resource exhaustion

### Desired State

Any node with database access (core-elx, web-ng) can become the cluster coordinator through automatic leader election. When the current leader fails, another eligible node takes over within seconds.

## Scope

### In Scope

- Leader election mechanism using Erlang's `:global` registry
- CoordinatorCandidate GenServer on eligible nodes
- Coordinator GenServer that starts coordination processes
- Graceful handoff when leader changes
- Telemetry for leader election events

### Out of Scope

- Multi-region leader election (same ERTS cluster only)
- Split-brain resolution (Erlang `:global` handles this)
- Changes to poller-elx (no DB access, cannot coordinate)

## Technical Approach

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ERTS Cluster                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌───────────────────┐              ┌───────────────────┐             │
│   │     core-elx      │              │      web-ng       │             │
│   │                   │              │                   │             │
│   │ ┌───────────────┐ │              │ ┌───────────────┐ │             │
│   │ │  Coordinator  │ │              │ │  Coordinator  │ │             │
│   │ │   Candidate   │ │              │ │   Candidate   │ │             │
│   │ └───────┬───────┘ │              │ └───────┬───────┘ │             │
│   │         │         │              │         │         │             │
│   └─────────┼─────────┘              └─────────┼─────────┘             │
│             │                                  │                        │
│             └──────────────┬───────────────────┘                        │
│                            ▼                                            │
│                 ┌─────────────────────┐                                 │
│                 │   :global registry  │                                 │
│                 │   (leader election) │                                 │
│                 └──────────┬──────────┘                                 │
│                            │                                            │
│                            ▼                                            │
│                 ┌─────────────────────┐                                 │
│                 │     Coordinator     │                                 │
│                 │   (current leader)  │                                 │
│                 │                     │                                 │
│                 │ • ClusterHealth     │                                 │
│                 │ • PollOrchestrator  │                                 │
│                 │ • Other coord procs │                                 │
│                 └─────────────────────┘                                 │
│                                                                         │
│   ┌───────────────────┐                                                 │
│   │    poller-elx     │  (not eligible - no DB access)                  │
│   └───────────────────┘                                                 │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Leader Election Flow

```
Node Startup:
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  1. Application starts                                                  │
│         │                                                               │
│         ▼                                                               │
│  2. CoordinatorCandidate starts                                         │
│         │                                                               │
│         ▼                                                               │
│  3. Try :global.register_name({:global, Coordinator}, self())           │
│         │                                                               │
│         ├─── :yes ──► Start Coordinator, become leader                  │
│         │                                                               │
│         └─── :no ───► Monitor current leader, wait for failover         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

Failover:
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  1. Current leader dies (crash, restart, network partition)             │
│         │                                                               │
│         ▼                                                               │
│  2. :global detects leader gone, releases name                          │
│         │                                                               │
│         ▼                                                               │
│  3. Candidates receive {:DOWN, ...} or periodic check triggers          │
│         │                                                               │
│         ▼                                                               │
│  4. First candidate to call :global.register_name wins                  │
│         │                                                               │
│         ▼                                                               │
│  5. New leader starts Coordinator, coordination processes resume        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Components

1. **Coordinator**: GenServer registered globally, starts/supervises coordination processes
2. **CoordinatorCandidate**: Runs on eligible nodes, attempts to become leader
3. **CoordinatorSupervisor**: Supervises coordination processes under the leader

### Oban Integration

Oban already has leader election via `pg` (process groups). The Oban leader election is separate from ours but compatible:

```elixir
# Oban's built-in leader election handles job scheduling
# Our coordinator handles ClusterHealth, PollOrchestrator
# Both can run on different nodes if needed, but typically same node
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `COORDINATOR_ELIGIBLE` | Whether this node can become coordinator | `true` for core-elx/web-ng |
| `COORDINATOR_ELECTION_INTERVAL` | How often to check for leader (ms) | `5000` |
| `COORDINATOR_TAKEOVER_DELAY` | Delay before attempting takeover (ms) | `1000` |

### Node Configuration

```elixir
# core-elx config/runtime.exs
config :serviceradar, ServiceRadar.Cluster.Coordinator,
  eligible: true,
  election_interval: 5_000,
  takeover_delay: 1_000

# web-ng config/runtime.exs
config :serviceradar, ServiceRadar.Cluster.Coordinator,
  eligible: true,  # Can take over if core-elx fails
  election_interval: 5_000,
  takeover_delay: 1_000

# poller-elx config/runtime.exs
config :serviceradar, ServiceRadar.Cluster.Coordinator,
  eligible: false  # No DB access, cannot coordinate
```

## Failure Scenarios

### Scenario 1: Core-elx Restarts

```
t=0    core-elx is leader
t=1    core-elx begins restart (SIGTERM)
t=2    Coordinator terminates gracefully, releases :global name
t=3    web-ng's CoordinatorCandidate detects leader gone
t=4    web-ng registers as new leader, starts coordination
t=10   core-elx comes back up
t=11   core-elx becomes candidate (web-ng still leader)
```

**Result**: ~2-3 second gap, web-ng takes over seamlessly

### Scenario 2: Core-elx Crashes

```
t=0    core-elx is leader
t=1    core-elx crashes (SIGKILL, OOM, etc.)
t=2    :global detects node down, releases name
t=3    web-ng's periodic check fires
t=4    web-ng registers as new leader
```

**Result**: ~5 second gap (election interval), web-ng takes over

### Scenario 3: Network Partition

```
t=0    core-elx and web-ng in same cluster
t=1    Network partition separates them
t=2    :global resolves partition (one side wins)
t=3    Winning side has coordinator, losing side has candidate
```

**Result**: Erlang's `:global` handles split-brain automatically

### Scenario 4: Rolling Deploy

```
t=0    core-elx is leader, web-ng is candidate
t=1    Deploy starts, core-elx pod terminated
t=2    web-ng becomes leader
t=5    New core-elx pod starts, becomes candidate
t=10   Deploy continues, web-ng pod terminated
t=11   core-elx becomes leader
t=15   New web-ng pod starts, becomes candidate
```

**Result**: Zero downtime, leadership transfers during deploy

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Split-brain (two leaders) | `:global` handles this; only one registration succeeds |
| Rapid leader flapping | Takeover delay prevents thrashing |
| State loss on failover | Coordination processes are stateless or use shared DB |
| web-ng becomes leader during high UI load | Monitor metrics, consider priority-based election in future |

## Success Criteria

1. **Automatic failover**: Leader failure results in new leader within 10 seconds
2. **No split-brain**: Only one active coordinator at any time
3. **Zero-downtime deploys**: Rolling restarts maintain coordination
4. **Observability**: Telemetry events for leader changes
5. **Backward compatible**: Existing single-node deployments work unchanged

## Future Enhancements

1. **Priority-based election**: Prefer core-elx over web-ng when both available
2. **Graceful handoff**: Current leader notifies candidate before shutdown
3. **Health-based election**: Only healthy nodes can become leader
4. **Multi-region support**: Cross-region leader election with latency awareness
