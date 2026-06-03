defmodule ServiceRadar.Inventory.EndpointInventoryFleetOrdinal do
  @moduledoc """
  Lazy allocation for the endpoint-inventory fleet ordinal dictionary.

  The ordinal is a derived `uid -> u32`-shaped surrogate for future in-memory
  fleet indexes. It references `ocsf_devices.uid`, is never allocated for
  `serviceradar:` service-component IDs, and is not embedded back into
  `ocsf_devices`.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @schema "platform"
  @table "device_fleet_ordinals"
  @sequence "#{@schema}.device_fleet_ordinals_ordinal_seq"

  @spec ensure_allocated(String.t() | nil, keyword()) :: {:ok, integer() | nil} | {:error, term()}
  def ensure_allocated(device_uid, opts \\ [])

  def ensure_allocated(nil, _opts), do: {:ok, nil}

  def ensure_allocated(device_uid, opts) when is_binary(device_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    case normalize_device_uid(device_uid) do
      nil ->
        {:ok, nil}

      "serviceradar:" <> _ ->
        {:ok, nil}

      uid ->
        allocate(repo, uid)
    end
  end

  @spec ordinal_for(String.t(), keyword()) :: integer() | nil
  def ordinal_for(device_uid, opts \\ []) when is_binary(device_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.one(
      from(o in @table,
        where: o.uid == ^device_uid and o.tombstoned == false,
        select: o.ordinal,
        limit: 1
      ),
      prefix: @schema
    )
  end

  defp allocate(repo, uid) do
    sql = """
    INSERT INTO #{@schema}.#{@table} (uid, ordinal, tombstoned, allocated_at)
    SELECT d.uid,
           nextval('#{@sequence}'::regclass)::integer,
           FALSE,
           now()
    FROM #{@schema}.ocsf_devices AS d
    WHERE d.uid = $1
      AND d.uid NOT LIKE 'serviceradar:%'
    ON CONFLICT (uid) DO NOTHING
    RETURNING ordinal
    """

    case SQL.query(repo, sql, [uid]) do
      {:ok, %{rows: [[ordinal]]}} ->
        {:ok, ordinal}

      {:ok, %{rows: []}} ->
        {:ok, ordinal_for(uid, repo: repo)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_device_uid(device_uid) do
    case String.trim(device_uid) do
      "" -> nil
      uid -> uid
    end
  end
end
