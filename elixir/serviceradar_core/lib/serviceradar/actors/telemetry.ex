defmodule ServiceRadar.Actors.Telemetry do
  @moduledoc """
  Telemetry integration for device actors.

  Provides metrics for monitoring device actor system health:
  - Actor count
  - Message throughput
  - Event buffer sizes
  - Health status distribution
  - Memory usage

  In the schema-agnostic architecture, each instance serves only one account
  and PostgreSQL schema isolation handles multi-tenancy at the infrastructure level.

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

  @prefix [:serviceradar, :actors, :device]

  @doc """
  Returns telemetry event definitions for metrics libraries.
  """
  def metrics do
    [
      # Gauges
      Telemetry.Metrics.last_value("#{metric_name(:count)}.value",
        tags: []
      ),
      Telemetry.Metrics.last_value("#{metric_name(:memory_bytes)}.value",
        tags: [],
        unit: :byte
      ),

      # Counters
      Telemetry.Metrics.counter("#{metric_name(:started)}.count",
        tags: [:partition_id]
      ),
      Telemetry.Metrics.counter("#{metric_name(:stopped)}.count",
        tags: [:reason]
      ),
      Telemetry.Metrics.counter("#{metric_name(:message)}.count",
        tags: [:device_id]
      ),
      Telemetry.Metrics.counter("#{metric_name(:event)}.count",
        tags: [:event_type]
      ),
      Telemetry.Metrics.counter("#{metric_name(:identity_update)}.count",
        tags: []
      ),
      Telemetry.Metrics.counter("#{metric_name(:health_check)}.count",
        tags: [:status]
      ),

      # Distributions
      Telemetry.Metrics.distribution("#{metric_name(:event_buffer_size)}.value",
        tags: [],
        buckets: [0, 10, 25, 50, 100]
      )
    ]
  end

  @doc """
  Emits actor started event.
  """
  def emit_started(device_id, partition_id) do
    :telemetry.execute(
      @prefix ++ [:started],
      %{count: 1},
      %{device_id: device_id, partition_id: partition_id}
    )
  end

  @doc """
  Emits actor stopped event.
  """
  def emit_stopped(device_id, reason) do
    :telemetry.execute(
      @prefix ++ [:stopped],
      %{count: 1},
      %{device_id: device_id, reason: reason}
    )
  end

  @doc """
  Emits message processed event.
  """
  def emit_message(device_id) do
    :telemetry.execute(
      @prefix ++ [:message],
      %{count: 1},
      %{device_id: device_id}
    )
  end

  @doc """
  Emits event recorded metric.
  """
  def emit_event(device_id, event_type) do
    :telemetry.execute(
      @prefix ++ [:event],
      %{count: 1},
      %{device_id: device_id, event_type: event_type}
    )
  end

  @doc """
  Emits identity update metric.
  """
  def emit_identity_update(device_id) do
    :telemetry.execute(
      @prefix ++ [:identity_update],
      %{count: 1},
      %{device_id: device_id}
    )
  end

  @doc """
  Emits health check metric.
  """
  def emit_health_check(device_id, status) do
    :telemetry.execute(
      @prefix ++ [:health_check],
      %{count: 1},
      %{device_id: device_id, status: status}
    )
  end

  @doc """
  Collects and emits aggregate metrics for all device actors.

  Called periodically to update gauge metrics.
  """
  def collect_metrics do
    devices = DeviceRegistry.list_devices()
    count = length(devices)

    # Emit count
    :telemetry.execute(
      @prefix ++ [:count],
      %{value: count},
      %{}
    )

    # Collect health status distribution
    health_counts =
      devices
      |> Enum.reduce(%{}, fn device, acc ->
        status = get_in(device, [:health, :status]) || :unknown
        Map.update(acc, status, 1, &(&1 + 1))
      end)

    Enum.each(health_counts, fn {status, status_count} ->
      :telemetry.execute(
        @prefix ++ [:health_status],
        %{count: status_count},
        %{status: status}
      )
    end)

    # Estimate memory usage (rough: ~1KB per actor base + state)
    memory_estimate = count * 1024

    :telemetry.execute(
      @prefix ++ [:memory_bytes],
      %{value: memory_estimate},
      %{}
    )
  end

  @doc """
  Returns a summary of device actor metrics.

  Useful for admin dashboards.
  """
  @spec summary() :: map()
  def summary do
    devices = DeviceRegistry.list_devices()

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

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp metric_name(suffix) do
    Enum.join(@prefix ++ [suffix], ".")
  end
end
