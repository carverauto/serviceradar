defmodule ServiceRadar.AgentTracker do
  @moduledoc """
  Tracks Go agents that push status to agent gateways.

  This is a simple in-memory tracker using ETS. Agents are tracked when they
  push status, with a TTL for stale agent detection.

  ## Usage

      # Track an agent status push
      AgentTracker.track_agent("docker-agent", %{service_count: 5})

      # List all tracked agents
      AgentTracker.list_agents()

      # Check if an agent is active (pushed status within TTL)
      AgentTracker.active?("docker-agent")

  ## Refused statuses

  An agent built before the edge-record cutover still sends durable data on the status RPCs.
  The gateway refuses it and counts it here with `record_refused_statuses/2`, per agent and
  source family. `list_agents/0` and `get_agent/1` report the counts as `refused_statuses`
  and the time of the latest refusal as `last_refused_at`; the edge pipeline readiness report
  reads them through `ServiceRadar.AgentRuntimeMetadata`. The counts live as long as the
  agent's tracker entry.
  """

  use GenServer

  require Logger

  @table :agent_tracker
  # {{agent_id, family}, count} and {{agent_id, :last_refused_at}, DateTime}. A table of its
  # own so an increment is one atomic update_counter, which a read-merge-insert of the
  # agent's info map in track_agent/2 cannot overwrite.
  @refused_table :agent_tracker_refused_statuses
  @stale_threshold_ms to_timeout(minute: 2)
  @cleanup_interval_ms to_timeout(minute: 1)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track an agent that has pushed status or announced itself via hello.
  """
  @spec track_agent(String.t(), map()) :: :ok
  def track_agent(agent_id, metadata \\ %{}) do
    now_mono = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()

    agent_info =
      agent_id
      |> existing_agent_info()
      |> Map.merge(normalize_metadata(metadata))
      |> Map.merge(%{
        agent_id: agent_id,
        last_seen: now,
        last_seen_mono: now_mono
      })
      |> Map.put_new(:service_count, 0)

    :ets.insert(@table, {agent_id, agent_info})

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
    refused = refused_by_agent()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {agent_id, info} ->
      age_ms = now - Map.get(info, :last_seen_mono, now)

      info
      |> Map.put(:active, age_ms < @stale_threshold_ms)
      |> Map.merge(Map.get(refused, agent_id, %{}))
    end)
    |> Enum.sort_by(& &1.agent_id)
  rescue
    ArgumentError -> []
  end

  @doc """
  Count statuses the gateway refused from an agent because their source is retired, keyed by
  source family. Returns `:first` when these are the first refusals recorded for the agent,
  else `:repeat`, so the caller can log once rather than on every push.
  """
  @spec record_refused_statuses(String.t(), %{String.t() => pos_integer()}) :: :first | :repeat
  def record_refused_statuses(agent_id, counts) when is_binary(agent_id) and is_map(counts) do
    first? = refused_statuses(agent_id) == %{}

    Enum.each(counts, fn {family, count} ->
      :ets.update_counter(@refused_table, {agent_id, family}, {2, count}, {{agent_id, family}, 0})
    end)

    :ets.insert(@refused_table, {{agent_id, :last_refused_at}, DateTime.utc_now()})
    if first?, do: :first, else: :repeat
  rescue
    ArgumentError -> :first
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
      [{_key, info}] -> Map.merge(info, refused_fields(agent_id))
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
    delete_refused(agent_id)
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
    :ets.new(@refused_table, [:set, :public, :named_table, write_concurrency: true])

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

  defp refused_by_agent do
    @refused_table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {{agent_id, key}, value}, acc ->
      Map.update(acc, agent_id, refused_entry(key, value, %{}), &refused_entry(key, value, &1))
    end)
  rescue
    ArgumentError -> %{}
  end

  defp refused_fields(agent_id) do
    @refused_table
    |> :ets.match_object({{agent_id, :_}, :_})
    |> Enum.reduce(%{}, fn {{_agent_id, key}, value}, acc -> refused_entry(key, value, acc) end)
  rescue
    ArgumentError -> %{}
  end

  defp refused_entry(:last_refused_at, at, fields), do: Map.put(fields, :last_refused_at, at)

  defp refused_entry(family, count, fields),
    do: Map.update(fields, :refused_statuses, %{family => count}, &Map.put(&1, family, count))

  defp refused_statuses(agent_id),
    do: agent_id |> refused_fields() |> Map.get(:refused_statuses, %{})

  defp delete_refused(agent_id) do
    :ets.match_delete(@refused_table, {{agent_id, :_}, :_})
  rescue
    ArgumentError -> true
  end

  defp existing_agent_info(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{_key, info}] -> info
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    compact_metadata(%{
      service_count: metadata_value(metadata, :service_count),
      partition: metadata_value(metadata, :partition),
      source_ip: metadata_value(metadata, :source_ip),
      gateway_id: metadata_value(metadata, :gateway_id),
      version: metadata_value(metadata, :version),
      hostname: metadata_value(metadata, :hostname),
      os: metadata_value(metadata, :os),
      arch: metadata_value(metadata, :arch),
      deployment_type: metadata_value(metadata, :deployment_type)
    })
  end

  defp normalize_metadata(_), do: %{}

  defp metadata_value(metadata, key) do
    case Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) do
      "" -> nil
      value -> value
    end
  end

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_stale_agents do
    now = System.monotonic_time(:millisecond)
    stale_threshold = now - to_timeout(day: 1)

    # Remove agents that haven't been seen in 24 hours
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {agent_id, info} ->
      last_seen_mono = Map.get(info, :last_seen_mono, now)

      if last_seen_mono < stale_threshold do
        :ets.delete(@table, agent_id)
        delete_refused(agent_id)
        Logger.debug("[AgentTracker] Removed stale agent: #{agent_id}")
      end
    end)
  rescue
    _ -> :ok
  end
end
