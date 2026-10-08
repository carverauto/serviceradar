defmodule ServiceRadar.Inventory.Identity.InterfaceMacs do
  @moduledoc """
  Records the universal MACs a device reports on its own interfaces.

  These rows corroborate identity but never identify or resolve a device by
  themselves. They are keyed per device so two records for one chassis can both
  retain the same observed interface MAC. Merge guards consume the rows only
  within the device's current partition and require reciprocal claims.

  The caller excludes virtual interface kinds. This module independently
  normalizes addresses, rejects locally administered and reserved values, and
  change-gates writes so unchanged polls do not rewrite every row.
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
        existing = registered_values(device_id, partition, actor)
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

  @doc "Values registered for a device within one normalized partition."
  @spec registered_values(String.t(), String.t() | nil, term()) :: MapSet.t()
  def registered_values(device_id, partition, actor) do
    query_opts = if actor, do: [actor: actor], else: []
    partition = normalize_partition(partition)

    DeviceInterfaceMac
    |> Ash.Query.filter(
      device_id == ^device_id and
        (partition == ^partition or (is_nil(partition) and ^partition == "default"))
    )
    |> Ash.read(query_opts)
    |> case do
      {:ok, rows} -> MapSet.new(rows, & &1.mac)
      _ -> MapSet.new()
    end
  rescue
    error ->
      Logger.warning(
        "Failed to load partitioned interface MACs for #{device_id}: #{inspect(error)}"
      )

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

  # This is a second, deliberately looser normalizer than Mac.normalize_mac/1:
  # it strips every non-hex character, because SNMP ifPhysAddress arrives in
  # more shapes than the identifier path has to cope with. Keep that difference,
  # but take the reserved-value rule from Mac rather than restating it, so the
  # two copies cannot drift on the question that matters for identity.
  #
  # Without the Mac.reserved_mac_value?/1 call, an interface reporting an
  # all-zero ifPhysAddress was written to device_interface_macs and then joined
  # against another device's :mac identifier by the duplicate sweep's
  # interface_mac_chassis_groups/0, producing an unattended two-device merge of
  # entirely unrelated hardware.
  defp normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.replace(~r/[^0-9A-Fa-f]/, "")
      |> String.upcase()

    if String.length(normalized) == 12 and not Mac.reserved_mac_value?(normalized),
      do: normalized
  end

  defp normalize(_value), do: nil

  defp normalize_partition(partition) when partition in [nil, ""], do: "default"
  defp normalize_partition(partition), do: partition
end
