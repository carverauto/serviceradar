defmodule ServiceRadarWebNGWeb.DeviceLive.QueryData do
  @moduledoc false

  require Logger

  @default_interfaces_limit 200

  def normalize_cursor(nil), do: nil
  def normalize_cursor(""), do: nil

  def normalize_cursor(cursor) when is_binary(cursor) do
    cursor = String.trim(cursor)
    if cursor == "", do: nil, else: cursor
  end

  def normalize_cursor(_), do: nil

  def parse_limit(nil, default, _max), do: default

  def parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  def parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  def parse_limit(_limit, default, _max), do: default

  def parse_positive_page(nil), do: 1

  def parse_positive_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  def parse_positive_page(page) when is_integer(page) and page > 0, do: page
  def parse_positive_page(_), do: 1

  def format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  def format_error(%ArgumentError{} = err), do: Exception.message(err)
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  def execute(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        viz = if is_map(resp["viz"]), do: resp["viz"]
        {results, nil, viz}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}", nil}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}", nil}
    end
  end

  def load_logs(srql_module, device_uid, scope, cursor, limit, identities \\ []) do
    opts = %{scope: scope, limit: limit, cursor: cursor}

    {results, pagination, error} =
      device_uid
      |> logs_queries(identities)
      |> Enum.reduce({[], %{}, nil}, fn query, {acc, page, err} ->
        case query_log_page(srql_module, query, opts) do
          {:ok, rows, pagination} -> {acc ++ rows, merge_logs_pagination(page, pagination), err}
          {:error, reason} -> {acc, page, err || reason}
        end
      end)

    {dedupe_log_rows(results), pagination, error}
  end

  def srql_for_tab_if_needed("interfaces", uid, limit, srql), do: srql_for_tab("interfaces", uid, limit, srql)

  def srql_for_tab_if_needed("flows", uid, limit, srql), do: srql_for_tab("flows", uid, limit, srql)

  def srql_for_tab_if_needed("logs", uid, limit, srql), do: srql_for_tab("logs", uid, limit, srql)

  def srql_for_tab_if_needed(_active_tab, _uid, _limit, srql), do: srql

  def srql_for_tab("interfaces", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_interfaces_query(device_uid)
    put_srql_tab(srql, "interfaces", query)
  end

  def srql_for_tab("flows", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_flows_query(device_uid)
    put_srql_tab(srql, "flows", query)
  end

  def srql_for_tab("logs", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_logs_query(device_uid)
    put_srql_tab(srql, "logs", query)
  end

  def srql_for_tab(_tab, device_uid, limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_device_query(device_uid, limit)
    put_srql_tab(srql, "devices", query)
  end

  def srql_for_tab(_tab, _device_uid, _limit, srql), do: srql

  def default_device_query(device_uid, limit) do
    "in:devices uid:\"#{escape_value(device_uid)}\" include_deleted:true limit:#{limit}"
  end

  def default_interfaces_query(device_uid, limit \\ @default_interfaces_limit) do
    "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d " <>
      "sort:if_name:asc limit:#{limit}"
  end

  def default_flows_query(device_uid) do
    "in:flows device_id:\"#{escape_value(device_uid)}\" time:last_24h sort:time:desc"
  end

  def default_logs_query(device_uid) do
    "in:logs device_id:\"#{escape_value(device_uid)}\" time:last_24h sort:timestamp:desc"
  end

  def logs_queries(device_uid, identities) when is_list(identities) do
    identity_queries =
      identities
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.flat_map(fn value ->
        escaped = escape_value(value)

        if ip_identity?(value) do
          ["in:logs source_ip:\"#{escaped}\" time:last_24h sort:timestamp:desc"]
        else
          ["in:logs source:\"#{escaped}\" time:last_24h sort:timestamp:desc"]
        end
      end)

    [default_logs_query(device_uid) | identity_queries]
  end

  defp query_log_page(srql_module, query, opts) do
    case srql_module.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        {:ok, Enum.filter(results, &is_map/1), pagination || %{}}

      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, Enum.filter(results, &is_map/1), %{}}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, error}

      {:ok, other} ->
        Logger.warning("Unexpected SRQL logs response: #{inspect(other)}")
        {:error, "Failed to load logs"}

      {:error, reason} ->
        Logger.warning("Failed to load device logs: #{inspect(reason)}")
        {:error, "Failed to load logs"}
    end
  end

  defp merge_logs_pagination(%{} = left, %{} = right) when map_size(left) == 0, do: right
  defp merge_logs_pagination(left, _right), do: left

  defp dedupe_log_rows(rows) do
    {deduped, _seen} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {acc, seen} ->
        key = log_row_key(row)

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [row], MapSet.put(seen, key)}
        end
      end)

    deduped
  end

  defp log_row_key(row) when is_map(row) do
    Map.get(row, "id") || Map.get(row, :id) ||
      {Map.get(row, "timestamp"), Map.get(row, "body"), Map.get(row, "source_ip")}
  end

  defp log_row_key(row), do: row

  defp ip_identity?(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  def escape_value(other), do: escape_value(to_string(other))

  defp put_srql_tab(srql, entity, query) do
    srql
    |> Map.put(:entity, entity)
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end
end
