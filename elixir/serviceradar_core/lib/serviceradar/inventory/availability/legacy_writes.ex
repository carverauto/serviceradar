defmodule ServiceRadar.Inventory.Availability.LegacyWrites do
  @moduledoc """
  Where the legacy availability writers put their value (`add-merged-device-availability`,
  design Decision 13).

  A legacy writer computes the value it always computed: the sweep's recovery and
  hysteresis, the sync path's non-nil `is_available`, a camera descriptor's status, an
  agent check-in, a composite check's verdict. It never writes
  `ocsf_devices.is_available`, which the merged resolver owns; it writes its value only
  to `device_availability_legacy` (`record/2`), computing against that table's previous
  value, not against the device column. Canonical Armis northbound sources with `legacy`
  semantics push that table's value, so it is kept for every device while such a source
  can exist.

  A device insert copies its initial `is_available` into the table (a trigger), so every
  device has a legacy value.
  """

  alias ServiceRadar.Repo

  @record """
  INSERT INTO platform.device_availability_legacy AS legacy (device_uid, is_available, updated_at)
  SELECT v.uid, v.available, (now() AT TIME ZONE 'utc')
  FROM unnest($1::text[], $2::boolean[]) AS v(uid, available)
  JOIN platform.ocsf_devices AS d ON d.uid = v.uid
  ORDER BY v.uid
  ON CONFLICT (device_uid) DO UPDATE
    SET is_available = EXCLUDED.is_available, updated_at = EXCLUDED.updated_at
    WHERE legacy.is_available IS DISTINCT FROM EXCLUDED.is_available
  """

  @doc """
  Moves the `is_available` of one device write's attributes to the compatibility table,
  in the caller's transaction, and removes it from the attributes. Attributes without a
  boolean `is_available` are returned unchanged.
  """
  @spec route_attrs(map(), String.t(), keyword()) :: map()
  def route_attrs(attrs, device_uid, query_opts \\ []) do
    case Map.fetch(attrs, :is_available) do
      {:ok, available?} when is_boolean(available?) ->
        record([{device_uid, available?}], query_opts)
        Map.delete(attrs, :is_available)

      _ ->
        attrs
    end
  end

  @doc """
  Writes legacy values to `device_availability_legacy`, write-on-change, in the caller's
  transaction. `values` are `{device_uid, boolean}`; for a uid given twice the last
  value wins, and a uid with no device row is skipped. Returns the rows written.
  """
  @spec record([{String.t(), boolean()}], keyword()) :: non_neg_integer()
  def record(values, query_opts \\ [])
  def record([], _query_opts), do: 0

  def record(values, query_opts) do
    {uids, available} =
      values
      |> Enum.filter(fn {uid, value} -> is_binary(uid) and is_boolean(value) end)
      |> Map.new()
      |> Enum.sort()
      |> Enum.unzip()

    case uids do
      [] ->
        0

      uids ->
        %{num_rows: written} = Repo.query!(@record, [uids, available], query_opts)
        written
    end
  end
end
