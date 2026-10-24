defmodule ServiceRadar.Inventory.Availability.LegacyWrites do
  @moduledoc """
  How the legacy availability writers behave in each mode (`add-merged-device-availability`,
  design Decisions 10 and 13), until stage d removes them.

  A legacy writer computes the value it always computed: the sweep's recovery and
  hysteresis, the sync path's non-nil `is_available`, a camera descriptor's status, an
  agent check-in, a composite check's verdict. Where that value goes depends on the mode.
  Sweep, sync, camera and composite writers read it with `admit/1` inside their own
  transaction, holding the mode-switch lock shared, so they cannot straddle a switch.
  An agent check-in reads `Mode.current/0` without that lock. In `cutover` or
  `authoritative` its compatibility write commits only with a device update that
  succeeds, so a failed check-in records nothing. A check-in that straddles a switch
  can still write the device column once; the device's next resolution rewrites it.

    * `legacy` and `shadow` (`Mode.legacy_column?/1`): the writer writes
      `ocsf_devices.is_available` exactly as before; a trigger copies each change into
      `device_availability_legacy`.
    * `cutover` and `authoritative`: the writer leaves `is_available` to the resolver and
      writes its value only to `device_availability_legacy` (`record/2`), computing
      against that table's previous value, not against the device column. Canonical
      Armis northbound sources in `legacy` semantics, and a rollback to `legacy`, read
      that table.

  A device insert copies its initial `is_available` into the table in every mode (a
  trigger), so a device created after cutover has a legacy value too.
  """

  alias ServiceRadar.Inventory.Availability.Mode
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
  Takes the mode-switch lock shared for the caller's transaction and returns the mode.
  Must run inside the writer's transaction, before it writes.
  """
  @spec admit(keyword()) :: Mode.t()
  def admit(query_opts \\ []), do: Mode.admit(query_opts)

  @doc """
  Routes the `is_available` of one device write's attributes by `mode`: unchanged while
  the legacy writers own the column; otherwise the value is recorded in the
  compatibility table and removed from the attributes. Attributes without a boolean
  `is_available` are returned unchanged.
  """
  @spec route_attrs(map(), String.t(), Mode.t(), keyword()) :: map()
  def route_attrs(attrs, device_uid, mode, query_opts \\ []) do
    case Map.fetch(attrs, :is_available) do
      {:ok, available?} when is_boolean(available?) ->
        if Mode.legacy_column?(mode) do
          attrs
        else
          record([{device_uid, available?}], query_opts)
          Map.delete(attrs, :is_available)
        end

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
