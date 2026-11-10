defmodule ServiceRadarWebNGWeb.DeviceLive.EventsData do
  @moduledoc false

  alias ServiceRadar.Repo
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require Logger

  @limit 50
  @default_time_window "last_24h"

  def load_events(srql_module, device_uid, scope, opts \\ []) do
    query = device_events_query(device_uid, opts)
    query_opts = %{scope: scope, limit: @limit}

    case srql_module.query(query, query_opts) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, Enum.filter(results, &is_map/1)}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, error}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Device events load failed for #{device_uid}: #{inspect(reason)}")
        {:error, "Failed to load events"}
    end
  end

  def device_events_query(device_uid, opts \\ []) do
    "in:events #{device_scope_token(device_uid, opts)} time:#{@default_time_window} sort:time:desc limit:#{@limit}"
  end

  # Resolves the device's inventory aliases once on CNPG and passes them as
  # values into SRQL so the StarRocks events statement executes an exact-key
  # match instead of joining `cnpg_platform.platform.device_inventory_aliases_catalog`
  # and scanning the 1 MiB JSON document columns with `LIKE`.
  def device_scope_token(device_uid, opts \\ [])

  def device_scope_token(device_uid, opts) when is_binary(device_uid) and device_uid != "" do
    with {:ok, aliases} <- resolve_device_identifiers(device_uid, opts),
         [_ | _] = identifiers <- normalize_identifiers([device_uid | aliases]) do
      format_device_uid_token(identifiers)
    else
      _ -> device_uid_token(device_uid)
    end
  rescue
    _ -> device_uid_token(device_uid)
  end

  def device_scope_token(device_uid, _opts), do: device_uid_token(device_uid)

  defp resolve_device_identifiers(device_uid, opts) do
    cond do
      is_list(opts[:identifiers]) ->
        {:ok, opts[:identifiers]}

      is_function(opts[:identifier_resolver], 1) ->
        opts[:identifier_resolver].(device_uid)

      true ->
        query_device_inventory_aliases(device_uid)
    end
  end

  defp query_device_inventory_aliases(device_uid) do
    case Repo.query(
           """
           SELECT alias
           FROM platform.device_inventory_aliases_catalog
           WHERE uid = $1 OR uid_alt = $1
           ORDER BY alias ASC
           """,
           [device_uid]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, rows |> Enum.map(&List.first/1) |> Enum.filter(&is_binary/1)}

      {:error, _reason} ->
        :error
    end
  end

  defp normalize_identifiers(identifiers) do
    identifiers
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp format_device_uid_token([single]), do: device_uid_token(single)

  defp format_device_uid_token(identifiers) do
    values = Enum.map_join(identifiers, ",", fn id -> ~s|"#{QueryData.escape_value(id)}"| end)
    "device_uid:[#{values}]"
  end

  defp device_uid_token(device_uid), do: ~s|device_uid:"#{QueryData.escape_value(device_uid)}"|
end
