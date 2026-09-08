defmodule ServiceRadar.Inventory.Identity.InterfaceMacs do
  @moduledoc """
  Records the MACs a device reports on its OWN interfaces.

  These are corroboration, not identity. `:interface_mac` is deliberately absent
  from `Ids.identifier_priority/0`, so it never resolves an update and never
  identifies a device on its own. Its single job is to answer one question that
  nothing could answer before: *is this other device actually a different piece
  of hardware, or another address of this same chassis?*

  ## Why a separate table, keyed per device

  A chassis reachable at two addresses becomes two device rows, each anchored by
  a different interface MAC (`f4:92:bf:75:c7:21` on the WAN, `…:2b` on the LAN).
  They share no identifier, so every merge path correctly refuses.

  Registering the LAN MAC as a `:mac` identifier of the WAN device cannot fix
  that: `DeviceIdentifier`'s uniqueness is `(identifier_type, identifier_value,
  partition)` and its upsert deliberately excludes `device_id`, because
  "silent last-writer-wins repoints collapsed distinct devices". The row stays
  with whoever owns it.

  A distinct identifier TYPE did not fix it either, and the reason is worth
  keeping: uniqueness there is still global per `(type, value, partition)`, and
  the two device rows of one chassis report the SAME interface MACs. The first to
  register owned all of them; its twin owned none and re-attempted every MAC on
  every poll forever, each attempt silently updating the other device's row and
  being counted as a success. Observed on farm01: 11 MACs on one row, 0 on the
  twin that reported 16.

  `DeviceInterfaceMac` is keyed `(device_id, mac)`. Each device records what IT
  observed, and two rows of one chassis may both claim the same MAC — which is
  precisely the signal that they are one chassis.

  ## Why not read the interface table directly

  `platform.discovered_interfaces` stores ~98 rows per interface state and grows
  without bound (see `refactor-interface-observation-persistence`). Scanning it
  inside a merge check would be unusable at 50k-1M devices.

  `device_interface_macs` is keyed `(device_id, mac)`, so "which MACs does this
  device claim" and "does it claim any of THESE" are both primary-key prefix
  scans. Cardinality is far lower than interface count -- measured on real
  hardware, a switch reporting 239 interfaces has 26 distinct MACs, because VLANs
  and subinterfaces share a base address -- so a 160-port chassis costs tens of
  rows, not hundreds.

  ## Two independent guards on what may be registered

  1. **Interface kind** — loopback, virtual, bridge and tunnel interfaces are
     excluded by the caller, reusing the mapper's existing
     `primary_identity_interface?/1`.
  2. **Locally-administered MACs are refused.** tap/veth/dummy/bond-member
     addresses are overwhelmingly locally administered, and a randomized or
     synthesised address is not evidence of hardware. On the deployment that
     motivated this, that filter removed 14 of 67 interface MACs and changed no
     outcome.

  ## Writes are change-gated

  Registering unconditionally would upsert every interface MAC on every poll —
  at 1M devices and 15 polls/day, hundreds of millions of writes per day for
  values that change only when hardware does. Existing values are read first
  (one indexed query per device) and only genuinely new MACs are written, so
  steady state costs reads and no writes.
  """

  alias ServiceRadar.Inventory.DeviceInterfaceMac
  alias ServiceRadar.Inventory.Identity.Mac

  require Ash.Query
  require Logger

  @doc """
  Register the universal MACs `device_id` reports on its own interfaces.

  `macs` are raw address strings; normalization, the locally-administered
  filter and the change gate are applied here. Returns the number written.
  """
  @spec register(String.t(), [String.t()], String.t() | nil, term()) :: non_neg_integer()
  def register(device_id, macs, partition, actor)

  def register(device_id, _macs, _partition, _actor)
      when not is_binary(device_id) or device_id == "", do: 0

  def register(device_id, macs, partition, actor) do
    case eligible(macs) do
      [] ->
        0

      eligible ->
        existing = registered_values(device_id, actor)
        missing = Enum.reject(eligible, &MapSet.member?(existing, &1))

        Enum.count(missing, &upsert(device_id, &1, partition, actor))
    end
  end

  @doc """
  The universal, normalized MACs from a list of raw addresses.

  Public so the merge guard and tests apply exactly the same rule the writer
  did, rather than a second copy of it.
  """
  @spec eligible([String.t()]) :: [String.t()]
  def eligible(macs) when is_list(macs) do
    macs
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&Mac.locally_administered_mac?/1)
    |> Enum.uniq()
  end

  def eligible(_macs), do: []

  @doc """
  Values registered as `:interface_mac` for a device.
  """
  @spec registered_values(String.t(), term()) :: MapSet.t()
  def registered_values(device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceInterfaceMac
    |> Ash.Query.filter(device_id == ^device_id)
    |> Ash.read(query_opts)
    |> case do
      {:ok, rows} -> MapSet.new(rows, & &1.mac)
      _ -> MapSet.new()
    end
  rescue
    error ->
      Logger.warning("Failed to load interface MACs for #{device_id}: #{inspect(error)}")
      MapSet.new()
  end

  defp upsert(device_id, value, partition, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceInterfaceMac
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_id,
      mac: value,
      partition: partition
    })
    |> Ash.create(query_opts)
    |> case do
      {:ok, _row} ->
        true

      {:error, error} ->
        Logger.warning(
          "Failed to register interface MAC #{value} for #{device_id}: #{inspect(error)}"
        )

        false
    end
  end

  defp normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.replace(~r/[^0-9A-Fa-f]/, "")
      |> String.upcase()

    if String.length(normalized) == 12, do: normalized
  end

  defp normalize(_value), do: nil
end
