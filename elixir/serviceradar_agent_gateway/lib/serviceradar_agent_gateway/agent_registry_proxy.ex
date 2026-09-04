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
    case live_control_capabilities(partition_id, agent_id) do
      {:ok, capabilities} ->
        capabilities

      :not_found ->
        GenServer.call(__MODULE__, {:delivery_capabilities, partition_id, agent_id})
    end
  end

  @doc false
  @spec sync_delivery_capabilities(String.t(), String.t(), [String.t()]) ::
          :ok | {:error, :proxy_unavailable}
  def sync_delivery_capabilities(partition_id, agent_id, capabilities)
      when is_binary(partition_id) and is_binary(agent_id) and is_list(capabilities) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:sync_delivery_capabilities, partition_id, agent_id, capabilities}, 1_000)

      nil ->
        {:error, :proxy_unavailable}
    end
  catch
    :exit, _reason -> {:error, :proxy_unavailable}
  end

  @impl true
  def init(_opts) do
    {:ok, live_control_capability_cache()}
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

  def handle_call({:sync_delivery_capabilities, partition_id, agent_id, capabilities}, _from, state) do
    {:reply, :ok, Map.put(state, {partition_id, agent_id}, capabilities)}
  end

  defp put_delivery_capabilities(state, agent_id, %{partition_id: partition_id, capabilities: capabilities})
       when is_binary(partition_id) and is_list(capabilities) do
    Map.put(state, {partition_id, agent_id}, capabilities)
  end

  defp put_delivery_capabilities(state, _agent_id, _metadata), do: state

  defp live_control_capabilities(partition_id, agent_id) when is_binary(partition_id) and is_binary(agent_id) do
    key = {:agent_control, partition_id, agent_id, node()}

    if Process.whereis(ProcessRegistry.registry_name()) do
      key
      |> ProcessRegistry.lookup()
      |> Enum.find_value(:not_found, &live_capabilities/1)
    else
      :not_found
    end
  catch
    :exit, _reason -> :not_found
  end

  defp live_control_capabilities(_partition_id, _agent_id), do: :not_found

  defp live_capabilities({pid, %{capabilities: capabilities}}) when is_pid(pid) and is_list(capabilities) do
    if node(pid) == node() and Process.alive?(pid), do: {:ok, capabilities}
  end

  defp live_capabilities(_entry), do: nil

  defp live_control_capability_cache do
    if Process.whereis(ProcessRegistry.registry_name()) do
      :agent_control
      |> ProcessRegistry.select_by_type()
      |> Enum.reduce(%{}, &put_live_control_capabilities/2)
    else
      %{}
    end
  catch
    :exit, _reason -> %{}
  end

  defp put_live_control_capabilities(
         {{:agent_control, partition_id, agent_id, registry_node}, pid, %{capabilities: capabilities}},
         state
       )
       when is_binary(partition_id) and is_binary(agent_id) and is_pid(pid) and is_list(capabilities) do
    if registry_node == node() and node(pid) == node() and Process.alive?(pid) do
      Map.put(state, {partition_id, agent_id}, capabilities)
    else
      state
    end
  end

  defp put_live_control_capabilities(_entry, state), do: state
end
