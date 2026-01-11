defmodule ServiceRadar.Infrastructure.EventBatcher do
  @moduledoc """
  Batches infrastructure events for efficient publishing to NATS JetStream.

  High-frequency events (like heartbeats) can overwhelm the message broker.
  This module collects events and publishes them in batches, reducing
  network overhead and improving throughput.

  ## Configuration

      config :serviceradar_core, ServiceRadar.Infrastructure.EventBatcher,
        # Maximum events to batch before flushing (default: 100)
        batch_size: 100,
        # Maximum time to wait before flushing (default: 1 second)
        flush_interval: 1_000,
        # Enable/disable batching (default: true)
        enabled: true

  ## Usage

  Instead of calling EventPublisher directly for high-frequency events,
  use EventBatcher:

      EventBatcher.queue_event(:state_change, %{
        entity_type: :agent,
        entity_id: "agent-123",
        tenant_id: "tenant-uuid",
        tenant_slug: "acme",
        old_state: :connected,
        new_state: :degraded
      })

  Events are automatically flushed when:
  - Batch size is reached
  - Flush interval elapses
  - `flush/0` is called explicitly

  ## Event Types That Should Use Batching

  - Heartbeat events (frequent, periodic)
  - Health status changes (can be frequent during incidents)
  - Metric updates

  ## Event Types That Should NOT Use Batching

  - Critical state changes (offline, failure) - publish immediately
  - Registration/deregistration events - publish immediately
  """

  use GenServer

  alias ServiceRadar.Infrastructure.EventPublisher

  require Logger

  @default_batch_size 100
  @default_flush_interval :timer.seconds(1)

  defstruct [
    :batch_size,
    :flush_interval,
    :flush_timer,
    :enabled,
    events: []
  ]

  # Client API

  @doc """
  Starts the event batcher.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Queues an event for batched publishing.

  ## Parameters

  - `event_type` - Type of event (:state_change, :heartbeat, :health_change)
  - `event_data` - Map with event details (entity_type, entity_id, tenant_id, etc.)

  ## Example

      EventBatcher.queue_event(:state_change, %{
        entity_type: :gateway,
        entity_id: "gateway-001",
        tenant_id: "uuid",
        tenant_slug: "acme",
        old_state: :healthy,
        new_state: :degraded,
        reason: :heartbeat_timeout
      })
  """
  @spec queue_event(atom(), map(), GenServer.server()) :: :ok
  def queue_event(event_type, event_data, server \\ __MODULE__) do
    GenServer.cast(server, {:queue, event_type, event_data})
  end

  @doc """
  Forces an immediate flush of all queued events.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  end

  @doc """
  Returns the current queue size.
  """
  @spec queue_size(GenServer.server()) :: non_neg_integer()
  def queue_size(server \\ __MODULE__) do
    GenServer.call(server, :queue_size)
  end

  @doc """
  Returns batcher statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    merged_opts = Keyword.merge(config, opts)

    state = %__MODULE__{
      batch_size: Keyword.get(merged_opts, :batch_size, @default_batch_size),
      flush_interval: Keyword.get(merged_opts, :flush_interval, @default_flush_interval),
      enabled: Keyword.get(merged_opts, :enabled, true),
      events: []
    }

    # Schedule periodic flush
    timer = schedule_flush(state.flush_interval)

    {:ok, %{state | flush_timer: timer}}
  end

  @impl true
  def handle_cast({:queue, event_type, event_data}, state) do
    if state.enabled do
      event = %{
        type: event_type,
        data: event_data,
        queued_at: System.monotonic_time(:millisecond)
      }

      new_events = [event | state.events]
      state = %{state | events: new_events}

      # Check if batch is full
      if length(new_events) >= state.batch_size do
        state = do_flush(state)
        {:noreply, state}
      else
        {:noreply, state}
      end
    else
      # Batching disabled - publish immediately
      publish_event(event_type, event_data)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  def handle_call(:queue_size, _from, state) do
    {:reply, length(state.events), state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      queue_size: length(state.events),
      batch_size: state.batch_size,
      flush_interval: state.flush_interval,
      enabled: state.enabled
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = do_flush(state)
    timer = schedule_flush(state.flush_interval)
    {:noreply, %{state | flush_timer: timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  defp do_flush(%{events: []} = state), do: state

  defp do_flush(%{events: events} = state) do
    # Reverse to maintain order (events were prepended)
    events_to_publish = Enum.reverse(events)
    count = length(events_to_publish)

    Logger.debug("Flushing #{count} batched events")

    # Publish events asynchronously
    Task.start(fn ->
      publish_batch(events_to_publish)
    end)

    :telemetry.execute(
      [:serviceradar, :infrastructure, :event_batcher, :flushed],
      %{count: count},
      %{}
    )

    %{state | events: []}
  end

  defp publish_batch(events) do
    Enum.each(events, fn %{type: event_type, data: event_data} ->
      publish_event(event_type, event_data)
    end)
  end

  defp publish_event(:state_change, data) do
    EventPublisher.publish_state_change(
      entity_type: data.entity_type,
      entity_id: data.entity_id,
      tenant_id: data.tenant_id,
      tenant_slug: data.tenant_slug,
      partition_id: Map.get(data, :partition_id),
      old_state: data.old_state,
      new_state: data.new_state,
      reason: Map.get(data, :reason),
      metadata: Map.get(data, :metadata, %{})
    )
  end

  defp publish_event(:health_change, data) do
    EventPublisher.publish_health_change(
      data.entity_type,
      data.entity_id,
      data.tenant_id,
      data.tenant_slug,
      data.is_healthy,
      partition_id: Map.get(data, :partition_id),
      reason: Map.get(data, :reason),
      metadata: Map.get(data, :metadata, %{})
    )
  end

  defp publish_event(:heartbeat_timeout, data) do
    EventPublisher.publish_heartbeat_timeout(
      data.entity_type,
      data.entity_id,
      data.tenant_id,
      data.tenant_slug,
      partition_id: Map.get(data, :partition_id),
      last_seen: Map.get(data, :last_seen),
      current_state: Map.get(data, :current_state),
      metadata: Map.get(data, :metadata, %{})
    )
  end

  defp publish_event(event_type, data) do
    Logger.warning("Unknown event type for batching: #{event_type}, data: #{inspect(data)}")
  end
end
