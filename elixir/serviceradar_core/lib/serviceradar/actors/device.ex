defmodule ServiceRadar.Actors.Device do
  @moduledoc """
  GenServer representing a device's runtime state.

  Device actors provide in-memory caching and stateful management for devices,
  enabling efficient operations like:
  - Identity resolution without repeated DB lookups
  - Event aggregation before persisting
  - Health status tracking with state machine semantics
  - Configuration caching

  ## Architecture

  Device actors are:
  - Lazily initialized on first access (not pre-created for all devices)
  - Registered in the tenant's Horde registry with key `{:device, device_id}`
  - Supervised by the tenant's Horde DynamicSupervisor
  - Automatically distributed across the cluster via Horde
  - Hibernated after inactivity to reduce memory usage

  ## Usage

      # Get or start a device actor
      {:ok, pid} = DeviceRegistry.get_or_start("tenant-id", "device-id")

      # Send commands to the actor
      Device.update_identity(pid, %{hostname: "server-01", ip: "10.0.0.1"})
      Device.record_event(pid, :health_check, %{status: :healthy, response_time: 15})
      Device.refresh_config(pid)

      # Query state
      state = Device.get_state(pid)

  ## State Structure

  The actor maintains the following state:
  - `identity` - Cached device identity (hostname, IP, MAC, etc.)
  - `health` - Current health status and metrics
  - `config` - Device-specific configuration
  - `events` - Recent events buffer (flushed periodically)
  - `last_seen` - Last activity timestamp
  - `last_persisted` - Last DB sync timestamp

  ## Hibernation

  After `@hibernate_after` milliseconds of inactivity, the process hibernates
  to reduce memory footprint. It wakes on next message.

  ## Persistence

  Events are buffered and flushed to the database periodically or when the
  buffer reaches a threshold. Identity changes are persisted immediately.
  """

  use GenServer, restart: :transient

  require Logger

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Inventory.Device, as: DeviceResource

  # Configuration
  @hibernate_after :timer.minutes(5)
  @event_flush_interval :timer.seconds(30)
  @event_buffer_max 100
  @health_check_interval :timer.seconds(60)
  @idle_timeout :timer.minutes(30)

  # Health states
  @health_states [:unknown, :healthy, :degraded, :unhealthy, :offline]

  defstruct [
    :tenant_id,
    :device_id,
    :partition_id,
    :identity,
    :health,
    :config,
    :events,
    :last_seen,
    :last_persisted,
    :started_at,
    :metrics
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          device_id: String.t(),
          partition_id: String.t() | nil,
          identity: map(),
          health: health_state(),
          config: map(),
          events: [event()],
          last_seen: DateTime.t(),
          last_persisted: DateTime.t() | nil,
          started_at: DateTime.t(),
          metrics: metrics()
        }

  @type health_state :: %{
          status: :unknown | :healthy | :degraded | :unhealthy | :offline,
          last_check: DateTime.t() | nil,
          response_time_ms: non_neg_integer() | nil,
          consecutive_failures: non_neg_integer(),
          details: map()
        }

  @type event :: %{
          type: atom(),
          timestamp: DateTime.t(),
          data: map()
        }

  @type metrics :: %{
          message_count: non_neg_integer(),
          event_count: non_neg_integer(),
          identity_updates: non_neg_integer(),
          health_checks: non_neg_integer()
        }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Starts a device actor for the given tenant and device.

  This is typically called by `DeviceRegistry.get_or_start/2`, not directly.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    device_id = Keyword.fetch!(opts, :device_id)
    partition_id = Keyword.get(opts, :partition_id)
    initial_identity = Keyword.get(opts, :identity, %{})

    GenServer.start_link(__MODULE__, %{
      tenant_id: tenant_id,
      device_id: device_id,
      partition_id: partition_id,
      identity: initial_identity
    })
  end

  @doc """
  Gets the current state of the device actor.
  """
  @spec get_state(pid()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Gets the cached identity for the device.
  """
  @spec get_identity(pid()) :: map()
  def get_identity(pid) do
    GenServer.call(pid, :get_identity)
  end

  @doc """
  Gets the current health status.
  """
  @spec get_health(pid()) :: health_state()
  def get_health(pid) do
    GenServer.call(pid, :get_health)
  end

  @doc """
  Updates the device identity.

  Changes are validated and persisted to the database.
  Broadcasts an identity update event.
  """
  @spec update_identity(pid(), map()) :: :ok | {:error, term()}
  def update_identity(pid, identity_updates) do
    GenServer.call(pid, {:update_identity, identity_updates})
  end

  @doc """
  Records an event for the device.

  Events are buffered and flushed periodically to reduce DB writes.
  """
  @spec record_event(pid(), atom(), map()) :: :ok
  def record_event(pid, event_type, event_data) do
    GenServer.cast(pid, {:record_event, event_type, event_data})
  end

  @doc """
  Records a health check result.

  Updates the health status and potentially triggers alerts.
  """
  @spec record_health_check(pid(), map()) :: :ok
  def record_health_check(pid, check_result) do
    GenServer.cast(pid, {:health_check, check_result})
  end

  @doc """
  Refreshes configuration from the database.
  """
  @spec refresh_config(pid()) :: :ok
  def refresh_config(pid) do
    GenServer.cast(pid, :refresh_config)
  end

  @doc """
  Forces an immediate flush of buffered events to the database.
  """
  @spec flush_events(pid()) :: :ok
  def flush_events(pid) do
    GenServer.call(pid, :flush_events)
  end

  @doc """
  Marks the device as seen (updates last_seen timestamp).
  """
  @spec touch(pid()) :: :ok
  def touch(pid) do
    GenServer.cast(pid, :touch)
  end

  @doc """
  Stops the device actor gracefully.

  Flushes any pending events before stopping.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # ===========================================================================
  # Server Callbacks
  # ===========================================================================

  @impl true
  def init(%{tenant_id: tenant_id, device_id: device_id} = init_state) do
    # Register in the tenant's Horde registry
    case register_self(tenant_id, device_id, init_state[:partition_id]) do
      {:ok, _} ->
        now = DateTime.utc_now()

        state = %__MODULE__{
          tenant_id: tenant_id,
          device_id: device_id,
          partition_id: init_state[:partition_id],
          identity: init_state[:identity] || %{},
          health: initial_health_state(),
          config: %{},
          events: [],
          last_seen: now,
          last_persisted: nil,
          started_at: now,
          metrics: initial_metrics()
        }

        # Load identity from DB if not provided
        state =
          if map_size(state.identity) == 0 do
            load_identity_from_db(state)
          else
            state
          end

        # Schedule periodic tasks
        schedule_event_flush()
        schedule_health_check()
        schedule_idle_check()

        Logger.debug("Device actor started: #{device_id} for tenant: #{tenant_id}")

        {:ok, state, @hibernate_after}

      {:error, {:already_registered, existing_pid}} ->
        Logger.debug("Device actor already exists: #{device_id}, pid: #{inspect(existing_pid)}")
        {:stop, {:already_registered, existing_pid}}

      {:error, reason} ->
        Logger.error("Failed to register device actor: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, touch_state(state), @hibernate_after}
  end

  @impl true
  def handle_call(:get_identity, _from, state) do
    {:reply, state.identity, touch_state(state), @hibernate_after}
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    {:reply, state.health, touch_state(state), @hibernate_after}
  end

  @impl true
  def handle_call({:update_identity, updates}, _from, state) do
    new_identity = Map.merge(state.identity, updates)

    case persist_identity(state.tenant_id, state.device_id, new_identity) do
      :ok ->
        new_state = %{
          state
          | identity: new_identity,
            last_persisted: DateTime.utc_now(),
            metrics: increment_metric(state.metrics, :identity_updates)
        }

        # Broadcast identity update
        broadcast_identity_update(new_state)

        {:reply, :ok, touch_state(new_state), @hibernate_after}

      {:error, reason} = error ->
        Logger.warning("Failed to persist identity for #{state.device_id}: #{inspect(reason)}")
        {:reply, error, state, @hibernate_after}
    end
  end

  @impl true
  def handle_call(:flush_events, _from, state) do
    new_state = do_flush_events(state)
    {:reply, :ok, new_state, @hibernate_after}
  end

  @impl true
  def handle_cast({:record_event, event_type, event_data}, state) do
    event = %{
      type: event_type,
      timestamp: DateTime.utc_now(),
      data: event_data
    }

    new_events = [event | state.events]

    # Flush if buffer is full
    new_state =
      if length(new_events) >= @event_buffer_max do
        do_flush_events(%{state | events: new_events})
      else
        %{state | events: new_events, metrics: increment_metric(state.metrics, :event_count)}
      end

    {:noreply, touch_state(new_state), @hibernate_after}
  end

  @impl true
  def handle_cast({:health_check, result}, state) do
    new_health = update_health_state(state.health, result)

    new_state = %{
      state
      | health: new_health,
        metrics: increment_metric(state.metrics, :health_checks)
    }

    # Record health check event
    event = %{
      type: :health_check,
      timestamp: DateTime.utc_now(),
      data: Map.merge(result, %{status: new_health.status})
    }

    new_state = %{new_state | events: [event | new_state.events]}

    # Broadcast if status changed
    if new_health.status != state.health.status do
      broadcast_health_change(new_state, state.health.status, new_health.status)
    end

    {:noreply, touch_state(new_state), @hibernate_after}
  end

  @impl true
  def handle_cast(:refresh_config, state) do
    new_state = load_config_from_db(state)
    {:noreply, touch_state(new_state), @hibernate_after}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, touch_state(state), @hibernate_after}
  end

  @impl true
  def handle_info(:flush_events, state) do
    schedule_event_flush()
    new_state = do_flush_events(state)
    {:noreply, new_state, @hibernate_after}
  end

  @impl true
  def handle_info(:health_check, state) do
    schedule_health_check()
    # Health checks are triggered externally; this just maintains the schedule
    {:noreply, state, @hibernate_after}
  end

  @impl true
  def handle_info(:idle_check, state) do
    idle_duration = DateTime.diff(DateTime.utc_now(), state.last_seen, :millisecond)

    if idle_duration > @idle_timeout do
      Logger.debug("Device actor idle timeout: #{state.device_id}")
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state, @hibernate_after}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Flush pending events before terminating
    if length(state.events) > 0 do
      do_flush_events(state)
    end

    # Unregister from Horde
    TenantRegistry.unregister(state.tenant_id, {:device, state.device_id})

    Logger.debug("Device actor terminated: #{state.device_id}, reason: #{inspect(reason)}")
    :ok
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp register_self(tenant_id, device_id, partition_id) do
    metadata = %{
      type: :device,
      device_id: device_id,
      partition_id: partition_id,
      node: Node.self(),
      started_at: DateTime.utc_now()
    }

    TenantRegistry.register(tenant_id, {:device, device_id}, metadata)
  end

  defp initial_health_state do
    %{
      status: :unknown,
      last_check: nil,
      response_time_ms: nil,
      consecutive_failures: 0,
      details: %{}
    }
  end

  defp initial_metrics do
    %{
      message_count: 0,
      event_count: 0,
      identity_updates: 0,
      health_checks: 0
    }
  end

  defp touch_state(state) do
    %{state | last_seen: DateTime.utc_now(), metrics: increment_metric(state.metrics, :message_count)}
  end

  defp increment_metric(metrics, key) do
    Map.update(metrics, key, 1, &(&1 + 1))
  end

  defp load_identity_from_db(state) do
    case DeviceResource.get_by_uid(state.device_id, tenant: state.tenant_id, authorize?: false) do
      {:ok, device} ->
        identity = %{
          uid: device.uid,
          name: device.name,
          hostname: device.hostname,
          ip: device.ip,
          mac: device.mac,
          type_id: device.type_id,
          vendor_name: device.vendor_name,
          model: device.model,
          os: device.os
        }

        %{state | identity: identity, partition_id: state.partition_id || device.gateway_id}

      {:error, _} ->
        Logger.debug("Device not found in DB: #{state.device_id}")
        state
    end
  end

  defp load_config_from_db(state) do
    # TODO: Load device-specific configuration from DB
    # For now, return state unchanged
    state
  end

  defp persist_identity(tenant_id, device_id, identity) do
    case DeviceResource.get_by_uid(device_id, tenant: tenant_id, authorize?: false) do
      {:ok, device} ->
        updates =
          identity
          |> Map.take([:name, :hostname, :ip, :mac, :vendor_name, :model, :os])
          |> Map.put(:last_seen_time, DateTime.utc_now())

        case Ash.update(device, updates, authorize?: false) do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        # Device doesn't exist yet, nothing to persist
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_flush_events(%{events: []} = state), do: state

  defp do_flush_events(state) do
    events = Enum.reverse(state.events)

    # TODO: Persist events to database
    # For now, just log them
    Logger.debug("Flushing #{length(events)} events for device: #{state.device_id}")

    %{state | events: [], last_persisted: DateTime.utc_now()}
  end

  defp update_health_state(current_health, result) do
    status = determine_health_status(result)
    now = DateTime.utc_now()

    consecutive_failures =
      if status in [:unhealthy, :offline] do
        current_health.consecutive_failures + 1
      else
        0
      end

    %{
      status: status,
      last_check: now,
      response_time_ms: result[:response_time_ms],
      consecutive_failures: consecutive_failures,
      details: Map.drop(result, [:status, :response_time_ms])
    }
  end

  defp determine_health_status(result) do
    cond do
      result[:status] in @health_states -> result[:status]
      result[:available] == true -> :healthy
      result[:available] == false -> :unhealthy
      result[:error] != nil -> :unhealthy
      true -> :unknown
    end
  end

  defp broadcast_identity_update(state) do
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "device:#{state.tenant_id}:#{state.device_id}",
      {:device_identity_updated, state.identity}
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "devices:#{state.tenant_id}",
      {:device_identity_updated, state.device_id, state.identity}
    )
  end

  defp broadcast_health_change(state, old_status, new_status) do
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "device:#{state.tenant_id}:#{state.device_id}",
      {:device_health_changed, old_status, new_status}
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "devices:#{state.tenant_id}",
      {:device_health_changed, state.device_id, old_status, new_status}
    )
  end

  # Scheduling helpers

  defp schedule_event_flush do
    Process.send_after(self(), :flush_events, @event_flush_interval)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout)
  end
end
