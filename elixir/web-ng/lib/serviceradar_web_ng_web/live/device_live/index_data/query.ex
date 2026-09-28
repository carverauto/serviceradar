defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Query do
  @moduledoc false

  require Logger

  # Size of one SRQL page while expanding "select all matching". This is a
  # fetch batch. The walk continues until the cursor is exhausted.
  @match_page_size 1_000

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

  @doc """
  Every device uid matching `query`.

  Pages until the cursor is exhausted. A full page is not the end of the
  selection. `window_scan:true` keeps the interactive cursor ceiling from
  stopping the walk.
  """
  @spec get_all_matching_uids(term(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def get_all_matching_uids(scope, query) do
    fetch_all_uids_paginated(srql_module(), scope, matching_uid_query(query), nil, [])
  end

  defp matching_uid_query(query) do
    base =
      (query || "")
      |> to_string()
      |> String.trim()
      |> normalize_device_count_query()

    base <> " window_scan:true sort:uid:asc limit:#{@match_page_size}"
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
    |> String.replace(~r/(^|\s)(?:limit|sort|cursor|window_scan):"[^"]*"(?=\s|$)/i, " ")
    |> String.replace(~r/(^|\s)(?:limit|sort|cursor|window_scan):\S+/i, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp fetch_all_uids_paginated(srql_module, scope, query, cursor, acc) do
    opts = if cursor, do: %{scope: scope, cursor: cursor}, else: %{scope: scope}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => results} = page} when is_list(results) ->
        pagination = Map.get(page, "pagination") || %{}
        next_cursor = Map.get(pagination, "next_cursor")
        acc = [device_uids(results) | acc]

        cond do
          advancing_cursor?(next_cursor, cursor) ->
            fetch_all_uids_paginated(srql_module, scope, query, next_cursor, acc)

          length(results) >= @match_page_size ->
            {:error, :selection_page_did_not_advance}

          true ->
            {:ok, finalize_uid_acc(acc)}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_page, other}}
    end
  end

  defp advancing_cursor?(next, current) do
    is_binary(next) and next != "" and next != current
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
