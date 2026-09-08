defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Query do
  @moduledoc false

  require Logger

  @all_matching_uid_limit 10_000

  def get_total_matching_count(scope, query) do
    srql_module = srql_module()
    query = (query || "") |> to_string() |> String.trim()

    full_query =
      query
      |> normalize_device_count_query()
      |> Kernel.<>(~s| stats:"count() as total"|)

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [count | _]}} ->
        extract_total_count(count)

      {:error, reason} ->
        Logger.warning("Device total count query failed: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  def include_inactive_inventory_params(params) when is_map(params) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    query =
      cond do
        query == "" ->
          "in:devices include_inactive:true"

        lifecycle_filter?(query) ->
          query

        String.starts_with?(String.downcase(query), "in:devices") ->
          "#{query} include_inactive:true"

        true ->
          query
      end

    Map.put(params, "q", query)
  end

  def include_inactive_inventory_params(params), do: params

  def parse_page_param(params) do
    case params["page"] do
      nil ->
        1

      "" ->
        1

      page when is_binary(page) ->
        case Integer.parse(page) do
          {n, _} when n > 0 -> n
          _ -> 1
        end

      page when is_integer(page) and page > 0 ->
        page

      _ ->
        1
    end
  end

  def get_all_matching_uids(scope, query) do
    fetch_all_uids_paginated(srql_module(), scope, query, nil, [], 0)
  end

  defp extract_total_count(%{} = row) do
    row
    |> Map.values()
    |> Enum.find_value(&parse_count_value/1)
  end

  defp extract_total_count(value), do: parse_count_value(value)

  defp parse_count_value(value) when is_integer(value), do: value
  defp parse_count_value(value) when is_float(value), do: trunc(value)
  defp parse_count_value(%Decimal{} = value), do: Decimal.to_integer(value)

  defp parse_count_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_count_value(_value), do: nil

  defp lifecycle_filter?(query) when is_binary(query) do
    String.match?(query, ~r/(^|\s)(?:is_active|active|include_inactive):/i)
  end

  defp normalize_device_count_query(""), do: "in:devices"

  defp normalize_device_count_query(query) when is_binary(query) do
    query = strip_device_count_control_tokens(query)

    cond do
      query == "" -> "in:devices"
      String.starts_with?(query, "in:") -> query
      true -> "in:devices #{query}"
    end
  end

  defp strip_device_count_control_tokens(query) do
    query
    |> String.replace(~r/(^|\s)(?:limit|sort|cursor):"[^"]*"(?=\s|$)/i, " ")
    |> String.replace(~r/(^|\s)(?:limit|sort|cursor):\S+/i, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  # Hard cap on the number of UIDs a select-all-matching expansion will fetch.
  # The 10_000-device guard at the bulk action call sites rejects oversized
  # selections, but without an internal bound this pager would still walk every
  # page of an unbounded result set before the caller saw the count.
  defp fetch_all_uids_paginated(srql_module, scope, query, cursor, acc, gathered) do
    full_query = "in:devices #{query} limit:1000"
    opts = if cursor, do: %{scope: scope, cursor: cursor}, else: %{scope: scope}

    case srql_module.query(full_query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        uids = device_uids(results)
        next_cursor = Map.get(pagination, "next_cursor")
        new_acc = [uids | acc]
        new_gathered = gathered + length(uids)

        cond do
          new_gathered >= @all_matching_uid_limit ->
            finalize_uid_acc(new_acc)

          is_binary(next_cursor) ->
            fetch_all_uids_paginated(srql_module, scope, query, next_cursor, new_acc, new_gathered)

          true ->
            finalize_uid_acc(new_acc)
        end

      {:ok, %{"results" => results}} when is_list(results) ->
        finalize_uid_acc([device_uids(results) | acc])

      _ ->
        finalize_uid_acc(acc)
    end
  end

  defp device_uids(results) do
    results
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
    |> Enum.filter(&is_binary/1)
  end

  defp finalize_uid_acc(acc) do
    acc
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.uniq()
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
