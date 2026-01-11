defmodule ServiceRadarAgentGateway.AgentRegistryProxy do
  @moduledoc """
  Owns AgentRegistry entries for Go agents connected through the gateway.

  Horde registry entries are tied to the registering process PID. gRPC request
  handlers are short-lived, so this proxy registers agents on a stable PID and
  updates their metadata/heartbeats.
  """

  use GenServer

  require Logger

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Cluster.TenantRegistry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec touch_agent(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def touch_agent(tenant_id, agent_id, metadata) do
    GenServer.call(__MODULE__, {:touch_agent, tenant_id, agent_id, metadata})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:touch_agent, tenant_id, agent_id, metadata}, _from, state) do
    case TenantRegistry.update_value(tenant_id, {:agent, agent_id}, fn existing ->
           existing
           |> Map.merge(metadata)
           |> Map.put(:last_heartbeat, DateTime.utc_now())
         end) do
      {_new, _old} ->
        {:reply, :ok, state}

      :error ->
        case AgentRegistry.register_agent(tenant_id, agent_id, metadata) do
          {:ok, _pid} ->
            {:reply, :ok, state}

          {:error, {:already_registered, _pid}} ->
            {:reply, :ok, state}

          {:error, reason} ->
            Logger.warning(
              "Failed to register agent #{agent_id} for tenant #{tenant_id}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end
    end
  end
end
