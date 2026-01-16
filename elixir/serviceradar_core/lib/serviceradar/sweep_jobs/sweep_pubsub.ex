defmodule ServiceRadar.SweepJobs.SweepPubSub do
  @moduledoc """
  PubSub broadcaster for sweep execution updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  In tenant-unaware mode, operates as a single instance since the DB schema
  is set by CNPG search_path credentials.

  ## Topics

  - `sweep:executions` - All execution updates
  - `sweep:executions:<execution_id>` - Updates for a specific execution

  ## Events

  - `{:sweep_execution_started, %{execution_id, sweep_group_id, agent_id, ...}}`
  - `{:sweep_execution_progress, %{execution_id, batch_num, total_batches, stats, ...}}`
  - `{:sweep_execution_completed, %{execution_id, status, stats, duration_ms, ...}}`
  - `{:sweep_execution_failed, %{execution_id, error_message, ...}}`
  """

  @pubsub ServiceRadar.PubSub

  @doc """
  Build the sweep executions topic.
  """
  def topic do
    "sweep:executions"
  end

  @doc """
  Build a topic for a specific execution.
  """
  def execution_topic(execution_id) when is_binary(execution_id) and execution_id != "" do
    "sweep:executions:#{execution_id}"
  end

  def execution_topic(_), do: nil

  @doc """
  Subscribe to all sweep execution updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, topic())
  end

  @doc """
  Subscribe to updates for a specific execution.
  """
  def subscribe_execution(execution_id) do
    case execution_topic(execution_id) do
      nil -> {:error, :invalid_execution_id}
      topic -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  @doc """
  Broadcast that an execution has started.
  """
  def broadcast_started(execution) do
    event = {:sweep_execution_started, %{
      execution_id: execution.id,
      sweep_group_id: execution.sweep_group_id,
      agent_id: execution.agent_id,
      started_at: execution.started_at,
      config_version: execution.config_version
    }}

    broadcast_to_all(event)
    broadcast_to_execution(execution.id, event)
  end

  @doc """
  Broadcast progress update during execution.

  Called after each batch is processed to show real-time progress.

  ## Parameters

  - `execution_id` - Execution being updated
  - `progress` - Map with:
    - `:batch_num` - Current batch number (1-indexed)
    - `:total_batches` - Total number of batches (if known)
    - `:hosts_processed` - Total hosts processed so far
    - `:hosts_available` - Available hosts so far
    - `:hosts_failed` - Failed hosts so far
    - `:devices_created` - New devices created so far
    - `:devices_updated` - Existing devices updated so far
  """
  def broadcast_progress(execution_id, progress) when is_map(progress) do
    event = {:sweep_execution_progress, Map.merge(progress, %{
      execution_id: execution_id,
      updated_at: DateTime.utc_now()
    })}

    broadcast_to_all(event)
    broadcast_to_execution(execution_id, event)
  end

  @doc """
  Broadcast that an execution has completed successfully.
  """
  def broadcast_completed(execution, stats) do
    event = {:sweep_execution_completed, %{
      execution_id: execution.id,
      sweep_group_id: execution.sweep_group_id,
      status: :completed,
      started_at: execution.started_at,
      completed_at: execution.completed_at,
      duration_ms: execution.duration_ms,
      hosts_total: stats[:hosts_total] || execution.hosts_total,
      hosts_available: stats[:hosts_available] || execution.hosts_available,
      hosts_failed: stats[:hosts_failed] || execution.hosts_failed,
      devices_created: stats[:devices_created] || 0,
      devices_updated: stats[:devices_updated] || 0
    }}

    broadcast_to_all(event)
    broadcast_to_execution(execution.id, event)
  end

  @doc """
  Broadcast that an execution has failed.
  """
  def broadcast_failed(execution, error_message) do
    event = {:sweep_execution_failed, %{
      execution_id: execution.id,
      sweep_group_id: execution.sweep_group_id,
      status: :failed,
      error_message: error_message,
      failed_at: DateTime.utc_now()
    }}

    broadcast_to_all(event)
    broadcast_to_execution(execution.id, event)
  end

  # Private helpers

  defp broadcast_to_all(event) do
    safe_broadcast(topic(), event)
  end

  defp broadcast_to_execution(execution_id, event) do
    case execution_topic(execution_id) do
      nil -> :ok
      topic -> safe_broadcast(topic, event)
    end
  end

  defp safe_broadcast(topic, event) do
    case Process.whereis(@pubsub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(@pubsub, topic, event)
    end
  end
end
