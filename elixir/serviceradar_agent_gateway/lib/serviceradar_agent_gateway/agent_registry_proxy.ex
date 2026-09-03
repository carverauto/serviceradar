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

  @doc "Returns capabilities negotiated for one authenticated edge principal."
  @spec delivery_capabilities(String.t(), String.t()) :: [String.t()]
  def delivery_capabilities(partition_id, agent_id) do
    GenServer.call(__MODULE__, {:delivery_capabilities, partition_id, agent_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:touch_agent, agent_id, metadata}, _from, state) do
    next_state = put_delivery_capabilities(state, agent_id, metadata)

    case ProcessRegistry.update_value({:agent, agent_id, node()}, fn existing ->
           existing
           |> Map.merge(metadata)
           |> Map.put(:last_heartbeat, DateTime.utc_now())
         end) do
      {_new_metadata, _old} ->
        {:reply, :ok, next_state}

      :error ->
        case AgentRegistry.register_agent(agent_id, metadata) do
          {:ok, _pid} ->
            {:reply, :ok, next_state}

          {:error, {:already_registered, _pid}} ->
            {:reply, :ok, next_state}
        end
    end
  end

  @impl true
  def handle_call({:delivery_capabilities, partition_id, agent_id}, _from, state) do
    capabilities = Map.get(state, {partition_id, agent_id}, [])

    {:reply, capabilities, state}
  end

  defp put_delivery_capabilities(state, agent_id, %{partition_id: partition_id, capabilities: capabilities})
       when is_binary(partition_id) and is_list(capabilities) do
    Map.put(state, {partition_id, agent_id}, capabilities)
  end

  defp put_delivery_capabilities(state, _agent_id, _metadata), do: state
end
