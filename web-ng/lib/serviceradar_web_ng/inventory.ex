defmodule ServiceRadarWebNG.Inventory do
  @moduledoc """
  Inventory context - delegates to Ash resources.

  This module provides backward-compatible functions that delegate
  to the underlying Ash resources in ServiceRadar.Inventory.
  """

  alias ServiceRadar.Inventory.Device

  require Ash.Query

  @doc """
  Lists devices with pagination.

  ## Options
    * `:limit` - Maximum number of devices to return (default: 100)
    * `:offset` - Number of devices to skip (default: 0)
    * `:actor` - The actor for authorization (optional for backward compat)
  """
  def list_devices(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    actor = Keyword.get(opts, :actor)

    query_opts = build_query_opts(actor)

    Device
    |> Ash.Query.sort(last_seen_time: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> devices
      {:error, _} -> []
    end
  end

  @doc """
  Gets a device by UID.

  Returns `nil` if device not found.
  """
  def get_device(uid, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    case Device.get_by_uid(uid, query_opts) do
      {:ok, device} -> device
      {:error, _} -> nil
    end
  end

  @doc """
  Gets a device by IP address.

  Returns the first matching device or `nil`.
  """
  def get_device_by_ip(ip, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    case Device.get_by_ip(ip, query_opts) do
      {:ok, [device | _]} -> device
      {:ok, []} -> nil
      {:error, _} -> nil
    end
  end

  @doc """
  Gets devices by poller ID.
  """
  def list_devices_by_poller(poller_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Device
    |> Ash.Query.for_read(:by_poller, %{poller_id: poller_id})
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> devices
      {:error, _} -> []
    end
  end

  @doc """
  Lists available devices.
  """
  def list_available_devices(opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Device
    |> Ash.Query.for_read(:available)
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> devices
      {:error, _} -> []
    end
  end

  @doc """
  Lists recently seen devices (within the last hour).
  """
  def list_recently_seen_devices(opts \\ []) do
    actor = Keyword.get(opts, :actor)
    query_opts = build_query_opts(actor)

    Device
    |> Ash.Query.for_read(:recently_seen)
    |> Ash.read(query_opts)
    |> case do
      {:ok, devices} -> devices
      {:error, _} -> []
    end
  end

  # Build query options, skipping authorization if no actor provided
  # (for backward compatibility during migration)
  defp build_query_opts(nil), do: [actor: system_actor(), authorize?: false]
  defp build_query_opts(actor), do: [actor: actor]

  # System actor for backward compatibility when no actor is provided
  defp system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.local",
      role: :super_admin
    }
  end
end
