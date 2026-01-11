defmodule ServiceRadar.Actors.DeviceRegistry do
  @moduledoc """
  Registry for device actors with lazy initialization.

  Provides discovery and management of device actors within tenant registries.
  Device actors are started on-demand when first accessed via `get_or_start/3`.

  ## Multi-Tenant Isolation

  Device actors are registered in per-tenant Horde registries managed by
  `ServiceRadar.Cluster.TenantRegistry`. This ensures:

  - Devices can only be accessed within their tenant
  - Cross-tenant device enumeration is prevented
  - Each tenant has isolated device actor state

  ## Usage

      # Get or start a device actor (lazy initialization)
      {:ok, pid} = DeviceRegistry.get_or_start("tenant-id", "device-id")

      # With partition context
      {:ok, pid} = DeviceRegistry.get_or_start("tenant-id", "device-id", partition_id: "partition-1")

      # Lookup existing actor
      case DeviceRegistry.lookup("tenant-id", "device-id") do
        {:ok, pid} -> Device.get_state(pid)
        :not_found -> # Device actor not running
      end

      # Find all active device actors for a tenant
      devices = DeviceRegistry.list_devices("tenant-id")

      # Count active device actors
      count = DeviceRegistry.count("tenant-id")

  ## Lazy Initialization

  Device actors are NOT pre-created for all devices in the database.
  They are started on-demand when first accessed. This reduces memory
  usage by only maintaining actors for actively monitored devices.

  Actors automatically stop after an idle timeout (configurable in Device module).
  """

  alias ServiceRadar.Actors.Device
  alias ServiceRadar.Cluster.TenantRegistry

  require Logger

  @doc """
  Gets an existing device actor or starts a new one.

  This is the primary entry point for accessing device actors.
  Returns `{:ok, pid}` or `{:error, reason}`.

  ## Options

    - `:partition_id` - Partition the device belongs to
    - `:identity` - Initial identity data (if starting new actor)

  ## Examples

      {:ok, pid} = DeviceRegistry.get_or_start("tenant-uuid", "device-001")

      {:ok, pid} = DeviceRegistry.get_or_start("tenant-uuid", "device-001",
        partition_id: "partition-1",
        identity: %{hostname: "server-01", ip: "10.0.0.1"}
      )
  """
  @spec get_or_start(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def get_or_start(tenant_id, device_id, opts \\ []) when is_binary(tenant_id) and is_binary(device_id) do
    case lookup(tenant_id, device_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_device_actor(tenant_id, device_id, opts)
    end
  end

  @doc """
  Looks up an existing device actor.

  Returns `{:ok, pid}` if the actor exists, `:not_found` otherwise.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, pid()} | :not_found
  def lookup(tenant_id, device_id) when is_binary(tenant_id) and is_binary(device_id) do
    case TenantRegistry.lookup(tenant_id, {:device, device_id}) do
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
  Lists all active device actors for a tenant.

  Returns a list of maps with device metadata and pid.
  """
  @spec list_devices(String.t()) :: [map()]
  def list_devices(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.select_by_type(tenant_id, :device)
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid, device_id: elem(key, 1)})
    end)
    |> Enum.filter(fn %{pid: pid} -> Process.alive?(pid) end)
  end

  @doc """
  Lists device actors for a specific partition within a tenant.
  """
  @spec list_devices_for_partition(String.t(), String.t()) :: [map()]
  def list_devices_for_partition(tenant_id, partition_id) when is_binary(tenant_id) do
    list_devices(tenant_id)
    |> Enum.filter(&(&1[:partition_id] == partition_id))
  end

  @doc """
  Counts active device actors for a tenant.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(tenant_id) when is_binary(tenant_id) do
    TenantRegistry.count_by_type(tenant_id, :device)
  end

  @doc """
  Stops a device actor.

  The actor will flush pending events before stopping.
  """
  @spec stop(String.t(), String.t()) :: :ok | :not_found
  def stop(tenant_id, device_id) when is_binary(tenant_id) and is_binary(device_id) do
    case lookup(tenant_id, device_id) do
      {:ok, pid} ->
        Device.stop(pid)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  Stops all device actors for a tenant.

  Use with caution - typically for tenant cleanup.
  """
  @spec stop_all(String.t()) :: :ok
  def stop_all(tenant_id) when is_binary(tenant_id) do
    list_devices(tenant_id)
    |> Enum.each(fn %{pid: pid} ->
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
  @spec get_state_if_running(String.t(), String.t()) :: Device.t() | nil
  def get_state_if_running(tenant_id, device_id) do
    case lookup(tenant_id, device_id) do
      {:ok, pid} -> Device.get_state(pid)
      :not_found -> nil
    end
  end

  @doc """
  Gets device health if actor is running, nil otherwise.
  """
  @spec get_health_if_running(String.t(), String.t()) :: Device.health_state() | nil
  def get_health_if_running(tenant_id, device_id) do
    case lookup(tenant_id, device_id) do
      {:ok, pid} -> Device.get_health(pid)
      :not_found -> nil
    end
  end

  @doc """
  Broadcasts a command to all device actors for a tenant.

  Useful for config refresh or other tenant-wide operations.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(tenant_id, message) when is_binary(tenant_id) do
    list_devices(tenant_id)
    |> Enum.each(fn %{pid: pid} ->
      send(pid, message)
    end)

    :ok
  end

  @doc """
  Updates identity for a device, starting the actor if needed.
  """
  @spec update_identity(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_identity(tenant_id, device_id, identity_updates) do
    case get_or_start(tenant_id, device_id) do
      {:ok, pid} -> Device.update_identity(pid, identity_updates)
      {:error, _} = error -> error
    end
  end

  @doc """
  Records an event for a device, starting the actor if needed.
  """
  @spec record_event(String.t(), String.t(), atom(), map()) :: :ok | {:error, term()}
  def record_event(tenant_id, device_id, event_type, event_data) do
    case get_or_start(tenant_id, device_id) do
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
  @spec record_health_check(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_health_check(tenant_id, device_id, check_result) do
    case get_or_start(tenant_id, device_id) do
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

  defp start_device_actor(tenant_id, device_id, opts) do
    child_spec = %{
      id: {:device, device_id},
      start:
        {Device, :start_link,
         [
           [
             tenant_id: tenant_id,
             device_id: device_id,
             partition_id: Keyword.get(opts, :partition_id),
             identity: Keyword.get(opts, :identity, %{})
           ]
         ]},
      restart: :transient,
      type: :worker
    }

    case TenantRegistry.start_child(tenant_id, child_spec) do
      {:ok, pid} ->
        Logger.debug("Started device actor: #{device_id} for tenant: #{tenant_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.warning("Failed to start device actor #{device_id}: #{inspect(reason)}")
        error
    end
  end
end
