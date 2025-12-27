defmodule ServiceRadarAgent.Application do
  @moduledoc """
  ServiceRadar Agent Application.

  This is a standalone Elixir release that runs on monitored hosts
  and joins the ServiceRadar ERTS cluster.

  The agent is responsible for:
  - Joining the distributed ERTS cluster via mTLS
  - Registering itself in the Horde distributed registry
  - Running check executors locally or via gRPC to external checkers
  - Reporting monitoring data to the poller via ERTS messaging
  - Collecting local system metrics (SNMP, WMI, etc.)

  ## Environment Variables

  - `AGENT_PARTITION_ID` - The partition this agent belongs to
  - `AGENT_ID` - Unique identifier for this agent
  - `AGENT_POLLER_ID` - The poller this agent reports to
  - `AGENT_CAPABILITIES` - Comma-separated list of capabilities (e.g., "snmp,wmi,disk")
  - `CLUSTER_HOSTS` - Comma-separated list of cluster nodes to join

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │                 ServiceRadar Core (Cloud)               │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Horde       │  │ libcluster   │  │ Data          │   │
  │  │ Registry    │  │              │  │ Aggregation   │   │
  │  └──────┬──────┘  └──────┬───────┘  └───────┬───────┘   │
  └─────────┼────────────────┼──────────────────┼───────────┘
            │ mTLS/ERTS      │                  │
            │                │                  │
  ┌─────────┼────────────────┼──────────────────┼───────────┐
  │         ▼                ▼                  ▼           │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Registration│  │ Cluster      │  │ Task          │   │
  │  │ Worker      │  │ Membership   │  │ Forwarder     │   │
  │  └─────────────┘  └──────────────┘  └───────────────┘   │
  │                    ServiceRadar Poller                   │
  └──────────────────────────────────────────────────────────┘
            │ mTLS/ERTS
            │
  ┌─────────┼───────────────────────────────────────────────┐
  │         ▼                                               │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Registration│  │ Check        │  │ gRPC Client   │   │
  │  │ Worker      │  │ Executor     │  │ (Checkers)    │   │
  │  └─────────────┘  └──────────────┘  └───────────────┘   │
  │                    ServiceRadar Agent                    │
  └──────────────────────────────────────────────────────────┘
            │ gRPC (local)
            │
  ┌─────────┼───────────────────────────────────────────────┐
  │         ▼                                               │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ SNMP        │  │ WMI          │  │ Disk          │   │
  │  │ Checker     │  │ Checker      │  │ Checker       │   │
  │  └─────────────┘  └──────────────┘  └───────────────┘   │
  │                 External Checkers (Go/Rust)              │
  └──────────────────────────────────────────────────────────┘
  ```

  Communication between Elixir components (agent, poller, core) happens via
  Erlang distributed messaging (ERTS) for full observability and remote debugging.

  External checkers (written in Go/Rust) are accessed via local gRPC.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    partition_id = System.get_env("AGENT_PARTITION_ID", "default")
    agent_id = System.get_env("AGENT_ID", generate_agent_id())
    poller_id = System.get_env("AGENT_POLLER_ID")

    capabilities = parse_capabilities(System.get_env("AGENT_CAPABILITIES", ""))

    Logger.info("Starting ServiceRadar Agent: #{agent_id} in partition: #{partition_id}")

    if poller_id do
      Logger.info("Agent will report to poller: #{poller_id}")
    end

    children = [
      # Agent-specific configuration store
      {ServiceRadarAgent.Config,
       partition_id: partition_id,
       agent_id: agent_id,
       poller_id: poller_id,
       capabilities: capabilities},

      # Registration worker - registers this agent in the distributed registry
      {ServiceRadar.Agent.RegistrationWorker,
       partition_id: partition_id,
       agent_id: agent_id,
       poller_id: poller_id,
       capabilities: capabilities},

      # Check executor - runs local checks and gRPC checks
      ServiceRadarAgent.CheckExecutor,

      # gRPC client pool for external checkers
      ServiceRadarAgent.CheckerPool
    ]

    opts = [strategy: :one_for_one, name: ServiceRadarAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_capabilities(capabilities_str) do
    capabilities_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp generate_agent_id do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    "agent-#{hostname}-#{:rand.uniform(9999)}"
  end
end
