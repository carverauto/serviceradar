defmodule ServiceRadar.Inventory.ConflictingIpRelease do
  @moduledoc """
  Releases a contested IP from a holder that no longer defends it.

  An interactive device edit claims an address through `Device :update`,
  which must stay fully atomic and therefore cannot pre-read the inventory.
  Callers that change `:ip` run this first: when another live device in the
  same partition already holds the address and the holder is not a healthy
  active device -- it is out of service (`is_active == false`) or stale
  (never seen, or not seen for over a day, mirroring the `is_stale`
  calculation) -- the holder's IP is cleared to `nil` with an audit note in
  `metadata`, so the subsequent update succeeds instead of dying on
  `ocsf_devices_unique_active_ip_idx`. The release mirrors
  `ServiceRadar.Edge.AgentGatewaySync`'s conflicting-owner release and
  writes through `:gateway_sync`, which accepts `:ip` and `:metadata`
  without identity side effects.

  Uniqueness is per `(partition, ip)`: the same address may live in more
  than one partition, so only holders in the claimant's partition are ever
  considered. When the holder is a healthy active device nothing is changed
  and `{:error, :defended}` is returned; the caller's update then reports
  `ip` as already taken, and the partial unique index remains the backstop
  for true races.

  Every operational failure fails open. A holder lookup or release that
  errors is logged and reported as `:ok`, so the caller proceeds to its
  update and the declared unique index delivers the usable error. This can
  only turn failures into successes, never the reverse.
  """

  alias ServiceRadar.Inventory.Device

  require Ash.Query
  require Logger

  @stale_after_seconds 24 * 60 * 60

  @doc """
  Vacates `ip` in `claimant_partition` for `claimant_uid` when every live
  holder there is a squatter.

  `opts` are forwarded to the holder lookup and release actions
  (`actor:`, `scope:`, ...).

  Returns `:ok` when there is nothing to contest, when every holder was
  released, or when a lookup/release failed (the caller's update still
  reports the outcome). Returns `{:error, :defended}` when a healthy active
  device owns the address.
  """
  @spec release_for_claim(String.t() | nil, String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :defended}
  def release_for_claim(ip, claimant_uid, claimant_partition, opts \\ [])

  def release_for_claim(nil, _claimant_uid, _partition, _opts), do: :ok
  def release_for_claim("", _claimant_uid, _partition, _opts), do: :ok

  def release_for_claim(ip, claimant_uid, partition, opts)
      when is_binary(ip) and is_binary(partition) and partition != "" do
    if String.trim(ip) == "" do
      :ok
    else
      release_holders(ip, claimant_uid, partition, opts)
    end
  end

  def release_for_claim(_ip, _claimant_uid, _partition, _opts), do: :ok

  defp release_holders(ip, claimant_uid, partition, opts) do
    query =
      Ash.Query.for_read(Device, :by_ip, %{ip: ip, partition: partition, include_deleted: false})

    case Ash.read(query, opts) do
      {:ok, holders} ->
        holders
        |> List.wrap()
        |> Enum.reject(&(&1.uid == claimant_uid))
        |> release_all(ip, claimant_uid, opts)

      {:error, reason} ->
        Logger.warning("Conflicting IP release lookup failed for #{ip}: #{inspect(reason)}")
        :ok
    end
  rescue
    reason ->
      Logger.warning("Conflicting IP release lookup failed for #{ip}: #{inspect(reason)}")
      :ok
  end

  defp release_all([], _ip, _claimant_uid, _opts), do: :ok

  defp release_all(holders, ip, claimant_uid, opts) do
    if Enum.any?(holders, &defended?/1) do
      {:error, :defended}
    else
      Enum.reduce_while(holders, :ok, fn holder, :ok ->
        case release_holder(holder, ip, claimant_uid, opts) do
          :ok -> {:cont, :ok}
          {:error, _} -> {:halt, :ok}
        end
      end)
    end
  end

  # A healthy active device defends its address. Anything else -- out of
  # service, never seen, or not seen for over a day -- is a squatter.
  defp defended?(%Device{is_active: false}), do: false
  defp defended?(%Device{last_seen_time: seen}), do: not stale?(seen)

  defp stale?(nil), do: true

  defp stale?(seen) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)
    DateTime.before?(seen, cutoff)
  end

  defp release_holder(holder, ip, claimant_uid, opts) do
    metadata =
      holder.metadata
      |> Map.new()
      |> Map.put("released_conflicting_active_ip", ip)
      |> Map.put("released_conflicting_active_ip_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("released_conflicting_active_ip_for_device", claimant_uid)

    holder
    |> Ash.Changeset.for_update(:gateway_sync, %{ip: nil, metadata: metadata})
    |> Ash.update(opts)
    |> case do
      {:ok, _} ->
        Logger.info(
          "Released conflicting active IP #{ip} from device #{holder.uid} for device #{claimant_uid}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to release conflicting active IP #{ip} from device #{holder.uid}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
