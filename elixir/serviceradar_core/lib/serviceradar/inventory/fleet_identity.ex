defmodule ServiceRadar.Inventory.FleetIdentity do
  @moduledoc """
  Persistent device dictionary for fleet membership.

  Allocation locks the canonical parent device and does not advance a sequence
  for existing assignments. Lifecycle hooks cover Ash and raw SQL writers.
  Backfill callers persist the returned keyset cursor and repeat until `done?`;
  each call reads and reconciles at most 500 canonical records. A new scan starts
  from nil, so changes behind a previous cursor are repaired by reconciliation.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Inventory.DeviceFleetOrdinal
  alias ServiceRadar.Inventory.FleetDictionaryEpoch
  alias ServiceRadar.Repo

  @max_page 500

  def ensure_device(uid, opts \\ [])
  def ensure_device(nil, _opts), do: {:ok, nil}

  def ensure_device(uid, opts) when is_binary(uid) do
    query_scalar("SELECT platform.ensure_device_fleet_ordinal($1)", [uid], opts)
  end

  def device_ordinal(uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.one(
      from(o in DeviceFleetOrdinal, where: o.uid == ^uid and not o.tombstoned, select: o.ordinal)
    )
  end

  def epoch(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    repo.one(from(e in FleetDictionaryEpoch, where: e.name == "inventory", select: e.epoch))
  end

  def backfill_devices(cursor \\ nil, opts \\ []) do
    with {:ok, limit} <- page_limit(opts) do
      sql = """
      WITH page AS MATERIALIZED (
        SELECT uid FROM platform.ocsf_devices
        WHERE ($1::text IS NULL OR uid > $1) ORDER BY uid LIMIT $2
      )
      SELECT uid, platform.ensure_device_fleet_ordinal(uid) FROM page ORDER BY uid
      """

      with {:ok, %{rows: rows}} <- SQL.query(Keyword.get(opts, :repo, Repo), sql, [cursor, limit]) do
        {:ok,
         %{
           cursor: last_device_cursor(rows, cursor),
           count: length(rows),
           done?: length(rows) < limit
         }}
      end
    end
  end

  defp page_limit(opts) do
    case Keyword.get(opts, :limit, @max_page) do
      n when is_integer(n) and n > 0 and n <= @max_page -> {:ok, n}
      _ -> {:error, :invalid_page_limit}
    end
  end

  defp last_device_cursor([], cursor), do: cursor
  defp last_device_cursor(rows, _cursor), do: rows |> List.last() |> hd()

  defp query_scalar(sql, params, opts) do
    case SQL.query(Keyword.get(opts, :repo, Repo), sql, params) do
      {:ok, %{rows: [[value]]}} ->
        {:ok, value}

      {:error, %Postgrex.Error{postgres: %{code: :sequence_generator_limit_exceeded}}} ->
        {:error, :identity_capacity_exhausted}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
