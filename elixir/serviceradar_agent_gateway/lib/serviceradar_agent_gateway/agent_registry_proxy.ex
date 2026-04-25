defmodule ServiceRadarAgentGateway.AgentRegistryProxy do
  @moduledoc """
  Owns AgentRegistry entries for Go agents connected through the gateway.

  Horde registry entries are tied to the registering process PID. gRPC request
  handlers are short-lived, so this proxy registers agents on a stable PID and
  updates their metadata/heartbeats.
  """

  use GenServer

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.ProcessRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec touch_agent(String.t(), map()) :: :ok | {:error, term()}
  def touch_agent(agent_id, metadata) do
    GenServer.call(__MODULE__, {:touch_agent, agent_id, metadata})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:touch_agent, agent_id, metadata}, _from, state) do
    case ProcessRegistry.update_value({:agent, agent_id, node()}, fn existing ->
           existing
           |> Map.merge(metadata)
           |> Map.put(:last_heartbeat, DateTime.utc_now())
         end) do
      {_new, _old} ->
        {:reply, :ok, state}

      :error ->
        case AgentRegistry.register_agent(agent_id, metadata) do
          {:ok, _pid} ->
            {:reply, :ok, state}

          {:error, {:already_registered, _pid}} ->
            {:reply, :ok, state}
        end
    end
  end
end
