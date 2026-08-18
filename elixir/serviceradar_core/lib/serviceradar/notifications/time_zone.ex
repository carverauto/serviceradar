defmodule ServiceRadar.Notifications.TimeZone do
  @moduledoc """
  Resolves notification schedule wall time through PostgreSQL's IANA database.

  ServiceRadar already requires PostgreSQL for every notification routing and
  delivery transition. PostgreSQL ships `pg_timezone_names` and applies the
  installed IANA daylight-saving rules through `AT TIME ZONE`, so using that
  existing runtime dependency avoids a second, independently updated time-zone
  database in the BEAM release.

  Both queries are parameterised. A schedule name is data, never SQL, and an
  unknown name is rejected by `supported?/1` before it can be persisted.
  """

  alias ServiceRadar.Repo

  @utc_zones ~w(UTC ETC/UTC GMT ETC/GMT Z ZULU ETC/ZULU)

  @doc "Returns whether `timezone` is an installed IANA name (UTC aliases included)."
  @spec supported?(term(), keyword()) :: boolean()
  def supported?(timezone, opts \\ [])

  def supported?(timezone, opts) when is_binary(timezone) and is_list(opts) do
    zone = String.trim(timezone)

    cond do
      zone == "" ->
        false

      utc_zone?(zone) ->
        true

      true ->
        case query(opts, "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)", [zone]) do
          {:ok, %{rows: [[true]]}} -> true
          _other -> false
        end
    end
  end

  def supported?(_timezone, _opts), do: false

  @doc "Converts a UTC instant to the wall clock in an installed IANA zone."
  @spec local_datetime(DateTime.t(), term(), keyword()) ::
          {:ok, NaiveDateTime.t()} | {:error, {:unsupported_timezone, term()}}
  def local_datetime(now, timezone, opts \\ [])

  def local_datetime(%DateTime{} = now, timezone, opts)
      when is_binary(timezone) and is_list(opts) do
    zone = String.trim(timezone)

    if utc_zone?(zone) do
      {:ok, DateTime.to_naive(now)}
    else
      case query(opts, "SELECT $1::timestamptz AT TIME ZONE $2", [now, zone]) do
        {:ok, %{rows: [[%NaiveDateTime{} = local]]}} ->
          {:ok, local}

        _other ->
          {:error, {:unsupported_timezone, timezone}}
      end
    end
  end

  def local_datetime(%DateTime{} = now, nil, opts), do: local_datetime(now, "Etc/UTC", opts)

  def local_datetime(%DateTime{}, timezone, _opts),
    do: {:error, {:unsupported_timezone, timezone}}

  defp query(opts, sql, params) do
    case Keyword.get(opts, :query) do
      fun when is_function(fun, 2) -> fun.(sql, params)
      _other -> Repo.query(sql, params)
    end
  end

  defp utc_zone?(timezone), do: String.upcase(timezone) in @utc_zones
end
