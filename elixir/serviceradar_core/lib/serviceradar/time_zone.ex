defmodule ServiceRadar.TimeZone do
  @moduledoc """
  Resolves installed PostgreSQL timezone names for user preferences and schedules.

  PostgreSQL owns the IANA catalog for the deployment, so this module neither
  ships nor caches a second timezone database.
  """

  alias ServiceRadar.Repo

  @utc_aliases ~w(UTC ETC/UTC GMT ETC/GMT Z ZULU ETC/ZULU)

  @doc "Returns whether `timezone` is an installed timezone name."
  @spec supported?(term(), keyword()) :: boolean()
  def supported?(timezone, opts \\ [])

  def supported?(timezone, opts) when is_binary(timezone) and is_list(opts) do
    zone = String.trim(timezone)

    cond do
      zone == "" ->
        false

      utc_alias?(zone) ->
        true

      true ->
        case query(opts, "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)", [zone]) do
          {:ok, %{rows: [[true]]}} -> true
          _ -> false
        end
    end
  end

  def supported?(_timezone, _opts), do: false

  @doc "Converts a UTC instant to the wall clock in an installed timezone."
  @spec local_datetime(DateTime.t(), term(), keyword()) ::
          {:ok, NaiveDateTime.t()} | {:error, {:unsupported_timezone, term()}}
  def local_datetime(now, timezone, opts \\ [])

  def local_datetime(%DateTime{} = now, timezone, opts)
      when is_binary(timezone) and is_list(opts) do
    zone = String.trim(timezone)

    if utc_alias?(zone) do
      {:ok, DateTime.to_naive(now)}
    else
      case query(opts, "SELECT $1::timestamptz AT TIME ZONE $2", [now, zone]) do
        {:ok, %{rows: [[%NaiveDateTime{} = local]]}} -> {:ok, local}
        _ -> {:error, {:unsupported_timezone, timezone}}
      end
    end
  end

  def local_datetime(%DateTime{} = now, nil, opts), do: local_datetime(now, "Etc/UTC", opts)

  def local_datetime(%DateTime{}, timezone, _opts),
    do: {:error, {:unsupported_timezone, timezone}}

  @doc "Returns the finite profile-safe timezone catalog from PostgreSQL."
  @spec profile_timezones(keyword()) :: {:ok, [String.t()]} | {:error, :catalog_unavailable}
  def profile_timezones(opts \\ []) when is_list(opts) do
    case query(opts, "SELECT name FROM pg_timezone_names", []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        zones =
          rows
          |> Enum.flat_map(fn
            [name] when is_binary(name) ->
              case normalize_preference(name) do
                {:ok, canonical_name} -> [canonical_name]
                {:error, :invalid_timezone} -> []
              end

            _ ->
              []
          end)
          |> then(&["Etc/UTC" | &1])
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, zones}

      _ ->
        {:error, :catalog_unavailable}
    end
  end

  @doc """
  Ordered names for the profile timezone picker.

  `Etc/UTC` is always first. Remaining names are unique and sorted. `extras`
  may include a persisted preference that is no longer in PostgreSQL's catalog
  so the current value stays visible.
  """
  @spec profile_picker_zones([String.t()], [String.t()]) :: [String.t()]
  def profile_picker_zones(zones, extras \\ []) when is_list(zones) and is_list(extras) do
    rest =
      (extras ++ zones)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == "Etc/UTC"))
      |> Enum.uniq()
      |> Enum.sort()

    ["Etc/UTC" | rest]
  end

  @doc "Normalizes a timezone preference before checking it against the catalog."
  @spec normalize_preference(term()) :: {:ok, String.t()} | {:error, :invalid_timezone}
  def normalize_preference(value) when is_binary(value) do
    zone = String.trim(value)

    cond do
      zone == "" -> {:error, :invalid_timezone}
      utc_alias?(zone) -> {:ok, "Etc/UTC"}
      profile_shape?(zone) -> {:ok, zone}
      true -> {:error, :invalid_timezone}
    end
  end

  def normalize_preference(_value), do: {:error, :invalid_timezone}

  @doc "Validates a normalized timezone preference against PostgreSQL's catalog."
  @spec validate_preference(term(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_timezone | :catalog_unavailable}
  def validate_preference(value, opts \\ []) do
    with {:ok, zone} <- normalize_preference(value),
         {:ok, zones} <- profile_timezones(opts),
         true <- zone in zones do
      {:ok, zone}
    else
      {:error, :catalog_unavailable} = error -> error
      _ -> {:error, :invalid_timezone}
    end
  end

  defp profile_shape?(zone) do
    String.contains?(zone, "/") and
      not Regex.match?(~r/\Aposix\//i, zone) and
      not Regex.match?(~r/\AEtc\/GMT[+-]\d+\z/i, zone)
  end

  defp query(opts, sql, params) do
    case Keyword.get(opts, :query) do
      fun when is_function(fun, 2) -> fun.(sql, params)
      _ -> Repo.query(sql, params)
    end
  end

  defp utc_alias?(timezone), do: String.upcase(timezone) in @utc_aliases
end
