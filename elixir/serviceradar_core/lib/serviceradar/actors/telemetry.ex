defmodule ServiceRadar.Actors.Telemetry do
  @moduledoc """
  Telemetry integration for device actors.

  Provides metrics for monitoring device actor system health:
  - Actor count per tenant
  - Message throughput
  - Event buffer sizes
  - Health status distribution
  - Memory usage

  ## Metrics

  The following metrics are emitted:

  - `serviceradar.actors.device.count` - Number of active device actors
  - `serviceradar.actors.device.message_count` - Messages processed
  - `serviceradar.actors.device.event_count` - Events recorded
  - `serviceradar.actors.device.identity_updates` - Identity update count
  - `serviceradar.actors.device.health_checks` - Health checks performed
  - `serviceradar.actors.device.health_status` - Distribution by health status

  ## Usage

  Attach this module's handlers in your application startup:

      ServiceRadar.Actors.Telemetry.attach()

  Or add metrics to your existing telemetry supervisor.
  """

  require Logger

  alias ServiceRadar.Actors.DeviceRegistry
  alias ServiceRadar.Cluster.TenantRegistry

  @prefix [:serviceradar, :actors, :device]

  @doc """
  Returns telemetry event definitions for metrics libraries.
  """
  def metrics do
    [
      # Gauges
      Telemetry.Metrics.last_value("#{metric_name(:count)}.value",
        tags: [:tenant_id]
      ),
      Telemetry.Metrics.last_value("#{metric_name(:memory_bytes)}.value",
        tags: [:tenant_id],
        unit: :byte
      ),

      # Counters
      Telemetry.Metrics.counter("#{metric_name(:started)}.count",
        tags: [:tenant_id, :partition_id]
      ),
      Telemetry.Metrics.counter("#{metric_name(:stopped)}.count",
        tags: [:tenant_id, :reason]
      ),
      Telemetry.Metrics.counter("#{metric_name(:message)}.count",
        tags: [:tenant_id, :device_id]
      ),
      Telemetry.Metrics.counter("#{metric_name(:event)}.count",
        tags: [:tenant_id, :event_type]
      ),
      Telemetry.Metrics.counter("#{metric_name(:identity_update)}.count",
        tags: [:tenant_id]
      ),
      Telemetry.Metrics.counter("#{metric_name(:health_check)}.count",
        tags: [:tenant_id, :status]
      ),

      # Distributions
      Telemetry.Metrics.distribution("#{metric_name(:event_buffer_size)}.value",
        tags: [:tenant_id],
        buckets: [0, 10, 25, 50, 100]
      )
    ]
  end

  @doc """
  Emits actor started event.
  """
  def emit_started(tenant_id, device_id, partition_id) do
    :telemetry.execute(
      @prefix ++ [:started],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id, partition_id: partition_id}
    )
  end

  @doc """
  Emits actor stopped event.
  """
  def emit_stopped(tenant_id, device_id, reason) do
    :telemetry.execute(
      @prefix ++ [:stopped],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id, reason: reason}
    )
  end

  @doc """
  Emits message processed event.
  """
  def emit_message(tenant_id, device_id) do
    :telemetry.execute(
      @prefix ++ [:message],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id}
    )
  end

  @doc """
  Emits event recorded metric.
  """
  def emit_event(tenant_id, device_id, event_type) do
    :telemetry.execute(
      @prefix ++ [:event],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id, event_type: event_type}
    )
  end

  @doc """
  Emits identity update metric.
  """
  def emit_identity_update(tenant_id, device_id) do
    :telemetry.execute(
      @prefix ++ [:identity_update],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id}
    )
  end

  @doc """
  Emits health check metric.
  """
  def emit_health_check(tenant_id, device_id, status) do
    :telemetry.execute(
      @prefix ++ [:health_check],
      %{count: 1},
      %{tenant_id: tenant_id, device_id: device_id, status: status}
    )
  end

  @doc """
  Collects and emits aggregate metrics for all device actors.

  Called periodically to update gauge metrics.
  """
  def collect_metrics do
    # Collect metrics per tenant
    TenantRegistry.list_registries()
    |> Enum.each(fn {_name, _pid} ->
      # For each tenant, collect device actor stats
      # Note: We'd need to track tenant_id per registry for this
      # For now, emit global metrics
      :ok
    end)

    # Emit global count
    :telemetry.execute(
      @prefix ++ [:count],
      %{value: count_all_actors()},
      %{tenant_id: "global"}
    )
  end

  @doc """
  Collects metrics for a specific tenant.
  """
  def collect_tenant_metrics(tenant_id) do
    devices = DeviceRegistry.list_devices(tenant_id)
    count = length(devices)

    # Emit count
    :telemetry.execute(
      @prefix ++ [:count],
      %{value: count},
      %{tenant_id: tenant_id}
    )

    # Collect health status distribution
    health_counts =
      devices
      |> Enum.reduce(%{}, fn device, acc ->
        status = get_in(device, [:health, :status]) || :unknown
        Map.update(acc, status, 1, &(&1 + 1))
      end)

    Enum.each(health_counts, fn {status, count} ->
      :telemetry.execute(
        @prefix ++ [:health_status],
        %{count: count},
        %{tenant_id: tenant_id, status: status}
      )
    end)

    # Estimate memory usage (rough: ~1KB per actor base + state)
    memory_estimate = count * 1024

    :telemetry.execute(
      @prefix ++ [:memory_bytes],
      %{value: memory_estimate},
      %{tenant_id: tenant_id}
    )
  end

  @doc """
  Returns a summary of device actor metrics for a tenant.

  Useful for admin dashboards.
  """
  @spec summary(String.t()) :: map()
  def summary(tenant_id) do
    devices = DeviceRegistry.list_devices(tenant_id)

    health_distribution =
      devices
      |> Enum.reduce(%{}, fn device, acc ->
        status = get_in(device, [:health, :status]) || :unknown
        Map.update(acc, status, 1, &(&1 + 1))
      end)

    partition_distribution =
      devices
      |> Enum.reduce(%{}, fn device, acc ->
        partition = device[:partition_id] || "unassigned"
        Map.update(acc, partition, 1, &(&1 + 1))
      end)

    %{
      total_count: length(devices),
      health_distribution: health_distribution,
      partition_distribution: partition_distribution,
      collected_at: DateTime.utc_now()
    }
  end

  @doc """
  Returns global summary across all tenants.

  WARNING: Admin/platform use only.
  """
  @spec global_summary() :: map()
  def global_summary do
    %{
      total_actors: count_all_actors(),
      collected_at: DateTime.utc_now()
    }
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp metric_name(suffix) do
    Enum.join(@prefix ++ [suffix], ".")
  end

  defp count_all_actors do
    # This is expensive - iterate all tenant registries
    # In production, maintain a counter instead
    0
  end
end
