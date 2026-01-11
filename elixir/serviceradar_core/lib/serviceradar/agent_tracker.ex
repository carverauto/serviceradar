defmodule ServiceRadar.AgentTracker do
  @moduledoc """
  Tracks Go agents that push status to agent gateways.

  This is a simple in-memory tracker using ETS. Agents are tracked when they
  push status, with a TTL for stale agent detection.

  ## Usage

      # Track an agent status push
      AgentTracker.track_agent("docker-agent", "default", %{service_count: 5})

      # List all tracked agents
      AgentTracker.list_agents()

      # Check if an agent is active (pushed status within TTL)
      AgentTracker.active?("docker-agent")
  """

  use GenServer

  require Logger

  @table :agent_tracker
  @stale_threshold_ms :timer.minutes(2)
  @cleanup_interval_ms :timer.minutes(1)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track an agent that has pushed status.
  """
  @spec track_agent(String.t(), String.t(), map()) :: :ok
  def track_agent(agent_id, tenant_slug, metadata \\ %{}) do
    now = System.monotonic_time(:millisecond)

    agent_info = %{
      agent_id: agent_id,
      tenant_slug: tenant_slug,
      last_seen: DateTime.utc_now(),
      last_seen_mono: now,
      service_count: Map.get(metadata, :service_count, 0),
      partition: Map.get(metadata, :partition),
      source_ip: Map.get(metadata, :source_ip)
    }

    :ets.insert(@table, {agent_id, agent_info})

    # Broadcast for UI updates
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:status",
      {:agent_status, agent_info}
    )

    :ok
  end

  @doc """
  List all tracked agents with their active status.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.map(fn {_key, info} ->
      age_ms = now - Map.get(info, :last_seen_mono, now)
      Map.put(info, :active, age_ms < @stale_threshold_ms)
    end)
    |> Enum.sort_by(& &1.agent_id)
  rescue
    ArgumentError -> []
  end

  @doc """
  Check if an agent is active (pushed status recently).
  """
  @spec active?(String.t()) :: boolean()
  def active?(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{_key, info}] ->
        now = System.monotonic_time(:millisecond)
        age_ms = now - Map.get(info, :last_seen_mono, now)
        age_ms < @stale_threshold_ms

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Get info for a specific agent.
  """
  @spec get_agent(String.t()) :: map() | nil
  def get_agent(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{_key, info}] -> info
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Remove an agent from tracking.
  """
  @spec remove_agent(String.t()) :: :ok
  def remove_agent(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Count of tracked agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for tracking agents
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Schedule periodic cleanup of stale entries
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_stale_agents()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_stale_agents do
    now = System.monotonic_time(:millisecond)
    stale_threshold = now - :timer.hours(24)

    # Remove agents that haven't been seen in 24 hours
    :ets.tab2list(@table)
    |> Enum.each(fn {agent_id, info} ->
      last_seen_mono = Map.get(info, :last_seen_mono, now)

      if last_seen_mono < stale_threshold do
        :ets.delete(@table, agent_id)
        Logger.debug("[AgentTracker] Removed stale agent: #{agent_id}")
      end
    end)
  rescue
    _ -> :ok
  end
end
