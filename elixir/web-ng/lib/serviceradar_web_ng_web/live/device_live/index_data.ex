defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData do
  @moduledoc false

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  require Ash.Query
  require Logger

  @sparkline_device_cap 200
  @sparkline_points_per_device 20
  @sparkline_bucket "5m"
  @sparkline_window "last_1h"
  @sparkline_threshold_ms 100.0
  @presence_window "last_24h"
  @presence_bucket "24h"
  @presence_device_cap 200
  @agent_availability_fresh_seconds 2 * 60 * 60

  def build_device_enrichments(scope, query, devices) do
    srql = srql_module()

    {icmp_sparklines, icmp_error} = load_icmp_sparklines(srql, devices, scope)
    effective_availability_by_device = load_effective_availability(devices, scope)
    {snmp_presence, sysmon_presence} = load_metric_presence(srql, devices, scope)
    sysmon_profiles_by_device = load_sysmon_profiles_for_devices(scope, devices)
    agent_device_uids = load_agent_device_uids(devices, scope)
    total_device_count = get_total_matching_count(scope, query)

    %{
      icmp_sparklines: icmp_sparklines,
      icmp_error: icmp_error,
      effective_availability_by_device: effective_availability_by_device,
      snmp_presence: snmp_presence,
      sysmon_presence: sysmon_presence,
      sysmon_profiles_by_device: sysmon_profiles_by_device,
      agent_device_uids: agent_device_uids,
      total_device_count: total_device_count
    }
  end

  defp load_agent_device_uids(devices, _scope) do
    devices
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(Map.get(&1, "uid") || Map.get(&1, "id")))
    |> DeviceStateData.agent_device_uids()
  end

  def load_availability_source_agent_options(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, %{results: agents}} -> agents
      {:ok, agents} when is_list(agents) -> agents
      _ -> []
    end
    |> Enum.map(fn agent ->
      display = agent.name || agent.host || agent.uid
      {"#{display} (#{agent.uid})", agent.uid}
    end)
  rescue
    reason ->
      Logger.warning("Failed to load availability source agents: #{inspect(reason)}")
      []
  end

  defp load_effective_availability(devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "uid") || Map.get(&1, "id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if device_uids == [] do
      %{}
    else
      rows =
        DeviceAgentAvailability
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.filter(device_uid in ^device_uids)
        |> Ash.Query.sort(checked_at: :desc, agent_id: :asc)
        |> Ash.read!(scope: scope)

      rows_by_device = Enum.group_by(rows, & &1.device_uid)

      devices
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn device, acc ->
        uid = Map.get(device, "uid") || Map.get(device, "id")
        availability_rows = Map.get(rows_by_device, uid, [])

        case effective_availability_from_rows(device, availability_rows) do
          nil -> acc
          value -> Map.put(acc, uid, value)
        end
      end)
    end
  rescue
    reason ->
      Logger.warning("Failed to load effective device availability: #{inspect(reason)}")
      %{}
  end

  defp effective_availability_from_rows(_device, []), do: nil

  defp effective_availability_from_rows(device, rows) do
    fresh_rows = Enum.filter(rows, &agent_availability_fresh?/1)

    if fresh_rows == [] do
      nil
    else
      effective_availability_from_fresh_rows(device, fresh_rows)
    end
  end

  defp effective_availability_from_fresh_rows(device, rows) do
    source_agent_id =
      device
      |> Map.get("availability_source_agent_id")
      |> blank_to_nil()

    if is_binary(source_agent_id) do
      rows
      |> Enum.find(&(&1.agent_id == source_agent_id))
      |> case do
        nil -> nil
        row -> row.is_available == true
      end
    else
      Enum.any?(rows, &(&1.is_available == true))
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp agent_availability_fresh?(row) do
    cutoff = DateTime.add(DateTime.utc_now(), -@agent_availability_fresh_seconds, :second)

    case Map.get(row, :checked_at) do
      %DateTime{} = observed_at -> DateTime.after?(observed_at, cutoff)
      _ -> false
    end
  end

  defp load_icmp_sparklines(srql_module, devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@sparkline_device_cap)

    if device_uids == [] do
      {%{}, nil}
    else
      query =
        Enum.join(
          [
            "in:timeseries_metrics",
            "metric_type:icmp",
            "uid:(#{Enum.map_join(device_uids, ",", &escape_list_value/1)})",
            "time:#{@sparkline_window}",
            "bucket:#{@sparkline_bucket}",
            "agg:avg",
            "series:uid",
            "limit:#{min(length(device_uids) * @sparkline_points_per_device, 4000)}"
          ],
          " "
        )

      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          {build_icmp_sparklines(rows), nil}

        {:ok, other} ->
          {%{}, "unexpected SRQL response: #{inspect(other)}"}

        {:error, reason} ->
          {%{}, format_error(reason)}
      end
    end
  end

  defp escape_list_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  defp load_metric_presence(srql_module, devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@presence_device_cap)

    if device_uids == [] do
      {%{}, %{}}
    else
      list = Enum.map_join(device_uids, ",", &escape_list_value/1)
      limit = min(length(device_uids) * 3, 2000)

      snmp_query =
        Enum.join(
          [
            "in:snmp_metrics",
            "uid:(#{list})",
            "time:#{@presence_window}",
            "bucket:#{@presence_bucket}",
            "agg:count",
            "series:uid",
            "limit:#{limit}"
          ],
          " "
        )

      sysmon_query =
        Enum.join(
          [
            "in:cpu_metrics",
            "uid:(#{list})",
            "time:#{@presence_window}",
            "bucket:#{@presence_bucket}",
            "agg:count",
            "series:uid",
            "limit:#{limit}"
          ],
          " "
        )

      snmp_presence =
        case srql_module.query(snmp_query, %{scope: scope}) do
          {:ok, %{"results" => rows}} -> presence_from_downsample(rows)
          _ -> %{}
        end

      sysmon_presence =
        case srql_module.query(sysmon_query, %{scope: scope}) do
          {:ok, %{"results" => rows}} -> presence_from_downsample(rows)
          _ -> %{}
        end

      {snmp_presence, sysmon_presence}
    end
  end

  defp presence_from_downsample(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      series = Map.get(row, "series")
      value = Map.get(row, "value")

      if is_binary(series) and series != "" and is_number(value) and value > 0 do
        Map.put(acc, series, true)
      else
        acc
      end
    end)
  end

  defp presence_from_downsample(_), do: %{}

  defp build_icmp_sparklines(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, &accumulate_icmp_point/2)
    |> Map.new(fn {device_uid, points} ->
      {device_uid, icmp_sparkline_data(points)}
    end)
  end

  defp build_icmp_sparklines(_), do: %{}

  defp accumulate_icmp_point(row, acc) do
    device_uid = Map.get(row, "series") || Map.get(row, "uid") || Map.get(row, "device_id")
    timestamp = Map.get(row, "timestamp")
    value_ms = latency_ms(Map.get(row, "value"))

    if is_binary(device_uid) and value_ms > 0 do
      Map.update(
        acc,
        device_uid,
        [%{ts: timestamp, v: value_ms}],
        fn existing -> existing ++ [%{ts: timestamp, v: value_ms}] end
      )
    else
      acc
    end
  end

  defp icmp_sparkline_data(points) do
    points =
      points
      |> Enum.sort_by(fn p -> p.ts end)
      |> Enum.take(-@sparkline_points_per_device)

    values = Enum.map(points, & &1.v)
    latest_ms = List.last(values) || 0.0
    tone = icmp_tone(latest_ms)
    title = icmp_title(points, latest_ms)

    %{points: values, latest_ms: latest_ms, tone: tone, title: title}
  end

  defp icmp_tone(latest_ms) do
    cond do
      latest_ms >= @sparkline_threshold_ms -> "warning"
      latest_ms > 0 -> "success"
      true -> "ghost"
    end
  end

  defp icmp_title(points, latest_ms) do
    case List.last(points) do
      %{ts: ts} when is_binary(ts) -> "ICMP #{format_ms(latest_ms)} · #{ts}"
      _ -> "ICMP #{format_ms(latest_ms)}"
    end
  end

  defp latency_ms(value) when is_float(value) or is_integer(value) do
    raw = if is_integer(value), do: value * 1.0, else: value
    if raw > 1_000_000.0, do: raw / 1_000_000.0, else: raw
  end

  defp latency_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> latency_ms(parsed)
      _ -> 0.0
    end
  end

  defp latency_ms(_), do: 0.0

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_ms(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1) <> "ms"
  end

  defp format_ms(value) when is_integer(value), do: Integer.to_string(value) <> "ms"
  defp format_ms(_), do: "—"

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  # Load device stats for cards using SRQL GROUP BY queries
  def load_device_stats(srql_module, scope) do
    query = "in:devices rollup_stats:inventory_summary"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [payload | _]}} when is_map(payload) ->
        stats = %{
          total: to_stats_int(Map.get(payload, "total")),
          available: to_stats_int(Map.get(payload, "available")),
          unavailable: to_stats_int(Map.get(payload, "unavailable")),
          by_type: parse_rollup_grouped_items(Map.get(payload, "by_type"), "type"),
          by_vendor: parse_rollup_grouped_items(Map.get(payload, "by_vendor"), "vendor_name"),
          by_risk_level: []
        }

        Logger.debug("Device stats rollup parsed: #{inspect(stats)}")
        stats

      {:ok, %{"results" => [%{"payload" => payload} | _]}} when is_map(payload) ->
        # Backward compatibility if SRQL returns wrapped payload rows.
        stats = %{
          total: to_stats_int(Map.get(payload, "total")),
          available: to_stats_int(Map.get(payload, "available")),
          unavailable: to_stats_int(Map.get(payload, "unavailable")),
          by_type: parse_rollup_grouped_items(Map.get(payload, "by_type"), "type"),
          by_vendor: parse_rollup_grouped_items(Map.get(payload, "by_vendor"), "vendor_name"),
          by_risk_level: []
        }

        Logger.debug("Device stats rollup parsed (wrapped payload): #{inspect(stats)}")
        stats

      {:ok, other} ->
        Logger.warning("Device stats rollup returned unexpected payload: #{inspect(other)}")
        default_device_stats()

      {:error, reason} ->
        Logger.warning("Device stats rollup query failed: #{inspect(reason)}")
        default_device_stats()
    end
  rescue
    e ->
      Logger.error("Device stats loading failed: #{inspect(e)}")
      default_device_stats()
  end

  defp default_device_stats do
    %{
      total: 0,
      available: 0,
      unavailable: 0,
      by_type: [],
      by_vendor: [],
      by_risk_level: []
    }
  end

  defp parse_rollup_grouped_items(items, key) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        name: to_string(Map.get(item, key) || "Unknown"),
        count: to_stats_int(Map.get(item, "count"))
      }
    end)
    |> Enum.filter(fn %{count: count} -> count > 0 end)
  end

  defp parse_rollup_grouped_items(_, _), do: []

  defp to_stats_int(nil), do: 0
  defp to_stats_int(value) when is_integer(value), do: value
  defp to_stats_int(value) when is_float(value), do: trunc(value)
  defp to_stats_int(%Decimal{} = value), do: Decimal.to_integer(value)

  defp to_stats_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp to_stats_int(_), do: 0

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
    srql_module = srql_module()
    fetch_all_uids_paginated(srql_module, scope, query, nil, [], 0)
  end

  # Hard cap on the number of UIDs a select-all-matching expansion will fetch.
  # The 10_000-device guard at the bulk action call sites rejects oversized
  # selections, but without an internal bound this pager would still walk every
  # page of an unbounded result set (one SRQL round-trip per 1_000 rows) before
  # the caller ever saw the count. Bounding the fetch here keeps a runaway
  # query from monopolizing the LiveView.
  @all_matching_uid_limit 10_000

  defp fetch_all_uids_paginated(srql_module, scope, query, cursor, acc, gathered) do
    full_query = "in:devices #{query} limit:1000"
    opts = if cursor, do: %{scope: scope, cursor: cursor}, else: %{scope: scope}

    case srql_module.query(full_query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        uids =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
          |> Enum.filter(&is_binary/1)

        next_cursor = Map.get(pagination, "next_cursor")
        new_acc = [uids | acc]
        new_gathered = gathered + length(uids)

        cond do
          new_gathered >= @all_matching_uid_limit ->
            # Bound reached: stop paging and return what we have. Callers that
            # compare against total_matching_count will still reject oversized
            # selections via the 10_000 cap.
            finalize_uid_acc(new_acc)

          is_binary(next_cursor) ->
            fetch_all_uids_paginated(srql_module, scope, query, next_cursor, new_acc, new_gathered)

          true ->
            finalize_uid_acc(new_acc)
        end

      {:ok, %{"results" => results}} when is_list(results) ->
        uids =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
          |> Enum.filter(&is_binary/1)

        finalize_uid_acc([uids | acc])

      _ ->
        finalize_uid_acc(acc)
    end
  end

  defp finalize_uid_acc(acc) do
    acc
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.uniq()
  end

  # Sysmon profile helpers
  # Note: Profile-per-device tracking removed - profiles now target devices via SRQL queries.
  # This function returns an empty map for profiles_by_device.
  def load_sysmon_profiles_for_devices(_scope, _devices) do
    %{}
  rescue
    _ -> %{}
  end
end
