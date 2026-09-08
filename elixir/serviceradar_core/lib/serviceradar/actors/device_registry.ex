defmodule ServiceRadar.Actors.DeviceRegistry do
  @moduledoc """
  Registry for device actors with lazy initialization.

  Provides discovery and management of device actors.
  Device actors are started on-demand when first accessed via `get_or_start/2`.

  ## Schema Isolation

  Each deployment is isolated at the infrastructure level.
  DB connection's search_path determines the schema.

  ## Usage

      # Get or start a device actor (lazy initialization)
      {:ok, pid} = DeviceRegistry.get_or_start("device-id")

      # With partition context
      {:ok, pid} = DeviceRegistry.get_or_start("device-id", partition_id: "partition-1")

      # Lookup existing actor
      case DeviceRegistry.lookup("device-id") do
        {:ok, pid} -> Device.get_state(pid)
        :not_found -> # Device actor not running
      end

      # Find all active device actors
      devices = DeviceRegistry.list_devices()

      # Count active device actors
      count = DeviceRegistry.count()

  ## Lazy Initialization

  Device actors are NOT pre-created for all devices in the database.
  They are started on-demand when first accessed. This reduces memory
  usage by only maintaining actors for actively monitored devices.

  Actors automatically stop after an idle timeout (configurable in Device module).
  """

  alias ServiceRadar.Actors.Device
  alias ServiceRadar.ProcessRegistry

  require Logger

  @doc """
  Gets an existing device actor or starts a new one.

  This is the primary entry point for accessing device actors.
  Returns `{:ok, pid}` or `{:error, reason}`.

  ## Options

    - `:partition_id` - Partition the device belongs to
    - `:identity` - Initial identity data (if starting new actor)

  ## Examples

      {:ok, pid} = DeviceRegistry.get_or_start("device-001")

      {:ok, pid} = DeviceRegistry.get_or_start("device-001",
        partition_id: "partition-1",
        identity: %{hostname: "server-01", ip: "10.0.0.1"}
      )
  """
  @spec get_or_start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start(device_id, opts \\ []) when is_binary(device_id) do
    case lookup(device_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_device_actor(device_id, opts)
    end
  end

  @doc """
  Looks up an existing device actor.

  Returns `{:ok, pid}` if the actor exists, `:not_found` otherwise.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :not_found
  def lookup(device_id) when is_binary(device_id) do
    case ProcessRegistry.lookup({:device, device_id}) do
      [{pid, _metadata}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :not_found
        end

      [] ->
        :not_found
    end
  end

  @doc """
  Lists all active device actors.

  Returns a list of maps with device metadata and pid.
  """
  @spec list_devices() :: [map()]
  def list_devices do
    :device
    |> ProcessRegistry.select_by_type()
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid, device_id: elem(key, 1)})
    end)
    |> Enum.filter(fn %{pid: pid} -> Process.alive?(pid) end)
  end

  @doc """
  Lists device actors for a specific partition.
  """
  @spec list_devices_for_partition(String.t()) :: [map()]
  def list_devices_for_partition(partition_id) do
    Enum.filter(list_devices(), &(&1[:partition_id] == partition_id))
  end

  @doc """
  Counts active device actors.
  """
  @spec count() :: non_neg_integer()
  def count do
    ProcessRegistry.count_by_type(:device)
  end

  @doc """
  Stops a device actor.

  The actor will flush pending events before stopping.
  """
  @spec stop(String.t()) :: :ok | :not_found
  def stop(device_id) when is_binary(device_id) do
    case lookup(device_id) do
      {:ok, pid} ->
        Device.stop(pid)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  Stops all device actors.

  Use with caution - typically for cleanup.
  """
  @spec stop_all() :: :ok
  def stop_all do
    Enum.each(list_devices(), fn %{pid: pid} ->
      try do
        Device.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  Gets device state if actor is running, nil otherwise.

  Convenience function that doesn't start the actor if not running.
  """
  @spec get_state_if_running(String.t()) :: Device.t() | nil
  def get_state_if_running(device_id) do
    case lookup(device_id) do
      {:ok, pid} -> Device.get_state(pid)
      :not_found -> nil
    end
  end

  @doc """
  Gets device health if actor is running, nil otherwise.
  """
  @spec get_health_if_running(String.t()) :: Device.health_state() | nil
  def get_health_if_running(device_id) do
    case lookup(device_id) do
      {:ok, pid} -> Device.get_health(pid)
      :not_found -> nil
    end
  end

  @doc """
  Broadcasts a command to all device actors.

  Useful for config refresh or other operations.
  """
  @spec broadcast(term()) :: :ok
  def broadcast(message) do
    Enum.each(list_devices(), fn %{pid: pid} ->
      send(pid, message)
    end)

    :ok
  end

  @doc """
  Updates identity for a device, starting the actor if needed.
  """
  @spec update_identity(String.t(), map()) :: :ok | {:error, term()}
  def update_identity(device_id, identity_updates) do
    case get_or_start(device_id) do
      {:ok, pid} -> Device.update_identity(pid, identity_updates)
      {:error, _} = error -> error
    end
  end

  @doc """
  Records an event for a device, starting the actor if needed.
  """
  @spec record_event(String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_event(device_id, event_type, event_data) do
    case get_or_start(device_id) do
      {:ok, pid} ->
        Device.record_event(pid, event_type, event_data)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Records a health check result for a device, starting the actor if needed.
  """
  @spec record_health_check(String.t(), map()) :: :ok | {:error, term()}
  def record_health_check(device_id, check_result) do
    case get_or_start(device_id) do
      {:ok, pid} ->
        Device.record_health_check(pid, check_result)
        :ok

      {:error, _} = error ->
        error
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp start_device_actor(device_id, opts) do
    child_spec = %{
      id: {:device, device_id},
      start:
        {Device, :start_link,
         [
           [
             device_id: device_id,
             partition_id: Keyword.get(opts, :partition_id),
             identity: Keyword.get(opts, :identity, %{})
           ]
         ]},
      restart: :transient,
      type: :worker
    }

    case ProcessRegistry.start_child(child_spec) do
      {:ok, pid} ->
        Logger.debug("Started device actor: #{device_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.warning("Failed to start device actor #{device_id}: #{inspect(reason)}")
        error
    end
  end
end
