defmodule ServiceRadar.SweepJobs.SweepPubSub do
  @moduledoc """
  PubSub broadcaster for sweep execution updates.

  Broadcasts to `ServiceRadar.PubSub` when available. If PubSub is not running,
  broadcasts are ignored.

  ## Topics

  - `sweep:executions:<tenant_id>` - All execution updates for a tenant
  - `sweep:executions:<tenant_id>:<execution_id>` - Updates for a specific execution

  ## Events

  - `{:sweep_execution_started, %{execution_id, sweep_group_id, agent_id, ...}}`
  - `{:sweep_execution_progress, %{execution_id, batch_num, total_batches, stats, ...}}`
  - `{:sweep_execution_completed, %{execution_id, status, stats, duration_ms, ...}}`
  - `{:sweep_execution_failed, %{execution_id, error_message, ...}}`
  """

  @pubsub ServiceRadar.PubSub

  @doc """
  Build the per-tenant sweep executions topic.
  """
  def topic(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    "sweep:executions:#{tenant_id}"
  end

  def topic(_), do: nil

  @doc """
  Build a topic for a specific execution.
  """
  def execution_topic(tenant_id, execution_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(execution_id) do
    "sweep:executions:#{tenant_id}:#{execution_id}"
  end

  def execution_topic(_, _), do: nil

  @doc """
  Subscribe to all sweep execution updates for a tenant.
  """
  def subscribe(tenant_id) do
    case topic(tenant_id) do
      nil -> {:error, :invalid_tenant}
      topic -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  @doc """
  Subscribe to updates for a specific execution.
  """
  def subscribe_execution(tenant_id, execution_id) do
    case execution_topic(tenant_id, execution_id) do
      nil -> {:error, :invalid_params}
      topic -> Phoenix.PubSub.subscribe(@pubsub, topic)
    end
  end

  @doc """
  Broadcast that an execution has started.
  """
  def broadcast_started(tenant_id, execution) do
    event = {:sweep_execution_started, %{
      execution_id: execution.id,
      sweep_group_id: execution.sweep_group_id,
      agent_id: execution.agent_id,
      started_at: execution.started_at,
      config_version: execution.config_version
    }}

    broadcast_to_tenant(tenant_id, event)
    broadcast_to_execution(tenant_id, execution.id, event)
  end

  @doc """
  Broadcast progress update during execution.

  Called after each batch is processed to show real-time progress.

  ## Parameters

  - `tenant_id` - Tenant identifier
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
  def broadcast_progress(tenant_id, execution_id, progress) when is_map(progress) do
    event = {:sweep_execution_progress, Map.merge(progress, %{
      execution_id: execution_id,
      updated_at: DateTime.utc_now()
    })}

    broadcast_to_tenant(tenant_id, event)
    broadcast_to_execution(tenant_id, execution_id, event)
  end

  @doc """
  Broadcast that an execution has completed successfully.
  """
  def broadcast_completed(tenant_id, execution, stats) do
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

    broadcast_to_tenant(tenant_id, event)
    broadcast_to_execution(tenant_id, execution.id, event)
  end

  @doc """
  Broadcast that an execution has failed.
  """
  def broadcast_failed(tenant_id, execution, error_message) do
    event = {:sweep_execution_failed, %{
      execution_id: execution.id,
      sweep_group_id: execution.sweep_group_id,
      status: :failed,
      error_message: error_message,
      failed_at: DateTime.utc_now()
    }}

    broadcast_to_tenant(tenant_id, event)
    broadcast_to_execution(tenant_id, execution.id, event)
  end

  # Private helpers

  defp broadcast_to_tenant(tenant_id, event) do
    case topic(tenant_id) do
      nil -> :ok
      topic -> safe_broadcast(topic, event)
    end
  end

  defp broadcast_to_execution(tenant_id, execution_id, event) do
    case execution_topic(tenant_id, execution_id) do
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
