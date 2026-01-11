# Design: Coordinator Leader Election

## Overview

This document describes the technical design for implementing dynamic leader election for the cluster coordinator role, enabling automatic failover when the current coordinator node becomes unavailable.

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Current Static Assignment                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌───────────────────┐              ┌───────────────────┐             │
│   │     core-elx      │              │      web-ng       │             │
│   │ cluster_coord:true│              │ cluster_coord:false│             │
│   │                   │              │                   │             │
│   │ ┌───────────────┐ │              │                   │             │
│   │ │ClusterSupervisor│              │  (no coordinator  │             │
│   │ │ • ClusterHealth│ │              │   processes)      │             │
│   │ │ • PollOrch    │ │              │                   │             │
│   │ └───────────────┘ │              └───────────────────┘             │
│   └───────────────────┘                                                 │
│                                                                         │
│   Problem: If core-elx goes down, coordination stops entirely           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Dynamic Leader Election                         │
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
│                 │     Coordinator     │  (runs on winning node)         │
│                 │ ┌─────────────────┐ │                                 │
│                 │ │CoordinatorSuper │ │                                 │
│                 │ │ • ClusterHealth │ │                                 │
│                 │ │ • PollOrch      │ │                                 │
│                 │ └─────────────────┘ │                                 │
│                 └─────────────────────┘                                 │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Design

### CoordinatorCandidate

The CoordinatorCandidate runs on every eligible node and participates in leader election.

```elixir
defmodule ServiceRadar.Cluster.CoordinatorCandidate do
  use GenServer
  require Logger

  @global_name {:global, ServiceRadar.Cluster.Coordinator}
  @default_election_interval 5_000
  @default_takeover_delay 1_000

  defstruct [:election_interval, :takeover_delay, :leader_ref, :is_leader]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      election_interval: opts[:election_interval] || @default_election_interval,
      takeover_delay: opts[:takeover_delay] || @default_takeover_delay,
      leader_ref: nil,
      is_leader: false
    }

    # Attempt to become leader on startup
    send(self(), :try_become_leader)
    {:ok, state}
  end

  @impl true
  def handle_info(:try_become_leader, state) do
    case :global.register_name(@global_name, self(), &resolve_conflict/3) do
      :yes ->
        Logger.info("Node #{node()} became cluster coordinator")
        emit_telemetry(:became_leader)
        start_coordinator()
        schedule_election_check(state.election_interval)
        {:noreply, %{state | is_leader: true, leader_ref: nil}}

      :no ->
        leader_pid = :global.whereis_name(@global_name)
        ref = if is_pid(leader_pid), do: Process.monitor(leader_pid), else: nil
        schedule_election_check(state.election_interval)
        {:noreply, %{state | is_leader: false, leader_ref: ref}}
    end
  end

  @impl true
  def handle_info(:election_check, %{is_leader: true} = state) do
    # Already leader, just reschedule
    schedule_election_check(state.election_interval)
    {:noreply, state}
  end

  def handle_info(:election_check, state) do
    # Check if leader is still alive
    case :global.whereis_name(@global_name) do
      :undefined ->
        # No leader, try to become one after delay
        Process.send_after(self(), :try_become_leader, state.takeover_delay)

      pid when is_pid(pid) ->
        # Leader exists, ensure we're monitoring
        ref = if state.leader_ref, do: state.leader_ref, else: Process.monitor(pid)
        schedule_election_check(state.election_interval)
        {:noreply, %{state | leader_ref: ref}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{leader_ref: ref} = state) do
    Logger.warning("Cluster coordinator down, attempting takeover...")
    emit_telemetry(:leader_down)
    Process.send_after(self(), :try_become_leader, state.takeover_delay)
    {:noreply, %{state | leader_ref: nil}}
  end

  # Conflict resolution: prefer the existing registration
  defp resolve_conflict(_name, pid1, pid2) do
    if node(pid1) < node(pid2), do: pid1, else: pid2
  end

  defp start_coordinator do
    DynamicSupervisor.start_child(
      ServiceRadar.Cluster.DynamicSupervisor,
      {ServiceRadar.Cluster.CoordinatorSupervisor, []}
    )
  end

  defp schedule_election_check(interval) do
    Process.send_after(self(), :election_check, interval)
  end

  defp emit_telemetry(event) do
    :telemetry.execute(
      [:serviceradar, :coordinator, event],
      %{time: System.system_time(:millisecond)},
      %{node: node()}
    )
  end
end
```

### Coordinator

The Coordinator is the globally registered process that manages coordination.

```elixir
defmodule ServiceRadar.Cluster.Coordinator do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__})
  end

  def current_leader do
    case :global.whereis_name({:global, __MODULE__}) do
      :undefined -> nil
      pid -> node(pid)
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{started_at: DateTime.utc_now()}}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("Coordinator terminating: #{inspect(reason)}")
    :global.unregister_name({:global, __MODULE__})
    :ok
  end
end
```

### CoordinatorSupervisor

Supervises the actual coordination processes.

```elixir
defmodule ServiceRadar.Cluster.CoordinatorSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ServiceRadar.Cluster.ClusterHealth,
      ServiceRadar.Cluster.PollOrchestrator
      # Add other coordination processes here
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

## Leader Election Protocol

### Election Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Election Flow                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Node A (core-elx)                    Node B (web-ng)                   │
│  ─────────────────                    ───────────────                   │
│                                                                         │
│  1. Start CoordinatorCandidate        1. Start CoordinatorCandidate     │
│         │                                    │                          │
│         ▼                                    ▼                          │
│  2. :global.register_name             2. :global.register_name          │
│     → :yes (wins)                        → :no (loses)                  │
│         │                                    │                          │
│         ▼                                    ▼                          │
│  3. Start CoordinatorSupervisor       3. Monitor leader (Node A)        │
│     • ClusterHealth                          │                          │
│     • PollOrchestrator                       │                          │
│         │                                    │                          │
│         ▼                                    ▼                          │
│  4. Running as leader                 4. Standby (periodic checks)      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Failover Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Failover Flow                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  t=0   Node A is leader, Node B is standby                              │
│                                                                         │
│  t=1   Node A crashes/restarts                                          │
│        • :global detects process down                                   │
│        • Releases global name                                           │
│                                                                         │
│  t=2   Node B receives {:DOWN, ...} from monitor                        │
│        • Waits takeover_delay (1s default)                              │
│                                                                         │
│  t=3   Node B calls :global.register_name                               │
│        • :yes → becomes new leader                                      │
│        • Starts CoordinatorSupervisor                                   │
│                                                                         │
│  t=4   Coordination continues on Node B                                 │
│                                                                         │
│  t=10  Node A restarts                                                  │
│        • Starts CoordinatorCandidate                                    │
│        • :global.register_name → :no                                    │
│        • Becomes standby, monitors Node B                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Configuration

### Runtime Configuration

```elixir
# config/runtime.exs
config :serviceradar, ServiceRadar.Cluster.CoordinatorCandidate,
  eligible: System.get_env("COORDINATOR_ELIGIBLE", "true") == "true",
  election_interval: String.to_integer(System.get_env("COORDINATOR_ELECTION_INTERVAL", "5000")),
  takeover_delay: String.to_integer(System.get_env("COORDINATOR_TAKEOVER_DELAY", "1000"))
```

### Node Eligibility

| Node Type | Default Eligible | Reason |
|-----------|-----------------|--------|
| core-elx | true | Has DB access, primary coordinator |
| web-ng | true | Has DB access, can coordinate |
| poller-elx | false | No DB access, cannot coordinate |

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:serviceradar, :coordinator, :became_leader]` | `time` | `node` |
| `[:serviceradar, :coordinator, :lost_leadership]` | `time` | `node`, `reason` |
| `[:serviceradar, :coordinator, :leader_down]` | `time` | `node`, `former_leader` |
| `[:serviceradar, :coordinator, :election_check]` | `time` | `node`, `current_leader` |

## Error Handling

### Split-Brain Prevention

Erlang's `:global` module handles split-brain scenarios:

1. Only one process can register a name at a time
2. Network partitions are detected via node monitoring
3. When partitions heal, `:global` resolves conflicts using the provided resolver function

### Rapid Flapping Prevention

The `takeover_delay` configuration prevents rapid leader changes:

```
Leader dies → Wait takeover_delay → Attempt registration
```

This ensures that transient network issues don't cause unnecessary leader changes.

## Testing Strategy

### Unit Tests

- Test CoordinatorCandidate state machine transitions
- Test configuration parsing
- Mock `:global` for deterministic testing

### Integration Tests

- Start two nodes in test cluster
- Verify only one becomes leader
- Kill leader, verify failover
- Restart original leader, verify it becomes standby

### Property-Based Tests

- Verify only one leader exists across random node start/stop sequences
- Verify all coordination processes run on exactly one node

## Migration Path

1. **Add new modules** without changing existing behavior
2. **Feature flag** coordinator_election_enabled (default: false)
3. **Test in staging** with flag enabled
4. **Enable in production** after validation
5. **Remove old static assignment** code
