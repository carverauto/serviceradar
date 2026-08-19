defmodule ServiceRadarWebNGWeb.DeviceLive.FlowData do
  @moduledoc false

  alias ServiceRadar.Repo

  require Logger

  def load_flows(srql_module, device_uid, scope, cursor, limit) do
    query = default_flows_query(device_uid)
    opts = %{scope: scope, limit: limit, cursor: cursor}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), pagination || %{}, nil}

      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), %{}, nil}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {[], %{}, error}

      {:ok, other} ->
        Logger.warning("Unexpected SRQL flows response for #{device_uid}: #{inspect(other)}")
        {[], %{}, "Failed to load flows data"}

      {:error, reason} ->
        Logger.warning("Failed to load device flows for #{device_uid}: #{inspect(reason)}")
        {[], %{}, "Failed to load flows data"}
    end
  end

  def load_zoomed_flows(srql_mod, query, opts) do
    case srql_mod.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => p}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), p || %{}, nil}

      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), %{}, nil}

      _ ->
        {[], %{}, "Failed to load flows for selected range"}
    end
  end

  # Presence must not use `sort:time:desc`. That plus the device_id OR-of-IPs
  # predicate walks the 24h time index and is what made has_flows time out
  # (then show a phantom Flows tab). Prefer per-IP EXISTS on the src/dst
  # indexes; fall back to unsorted SRQL limit:1 when Repo is unavailable.
  def has_flows?(srql_module, device_uid, scope) do
    case cheap_flow_presence(device_uid) do
      {:ok, present} -> present
      :error -> srql_flow_presence(srql_module, device_uid, scope)
    end
  end

  def empty_flow_stats_bundle do
    {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
  end

  def load_device_flow_stats(srql_mod, device_uid, scope) do
    load_device_flow_stats(
      srql_mod,
      device_uid,
      scope,
      "in:flows device_id:\"#{escape_value(device_uid)}\" time:last_24h"
    )
  end

  def load_device_flow_stats(srql_mod, _device_uid, scope, base) do
    tasks = [
      Task.async(fn -> {:summary, load_device_flow_summary(srql_mod, scope, base)} end),
      Task.async(fn ->
        {:protocols, load_device_flow_protocols(srql_mod, scope, base)}
      end),
      Task.async(fn ->
        {:talkers, load_device_flow_top_n(srql_mod, scope, base, "src_endpoint_ip")}
      end),
      Task.async(fn ->
        {:destinations, load_device_flow_top_n(srql_mod, scope, base, "dst_endpoint_ip")}
      end),
      Task.async(fn ->
        {:ports, load_device_flow_top_n(srql_mod, scope, base, "dst_endpoint_port")}
      end),
      Task.async(fn ->
        {:directions, load_device_flow_top_n(srql_mod, scope, base, "direction")}
      end),
      Task.async(fn ->
        {:services, load_device_flow_top_n(srql_mod, scope, base, "dst_service_label")}
      end),
      Task.async(fn -> {:timeseries, load_device_flow_timeseries(srql_mod, scope, base)} end)
    ]

    results = safe_yield_many(tasks, 10_000)

    summary = Map.get(results, :summary, %{})
    protocols = Map.get(results, :protocols, [])
    talkers = Map.get(results, :talkers, [])
    destinations = Map.get(results, :destinations, [])
    ports = Map.get(results, :ports, [])
    directions = Map.get(results, :directions, [])
    services = Map.get(results, :services, [])
    timeseries = Map.get(results, :timeseries, [])

    proto_json =
      protocols
      |> Enum.map(fn row -> %{label: row[:name] || "unknown", value: row[:bytes] || 0} end)
      |> Jason.encode!()

    sparkline_json =
      timeseries
      |> Enum.map(fn %{t: t, v: v} -> %{t: t, v: v} end)
      |> Jason.encode!()

    chart_points =
      timeseries
      |> Enum.map(fn %{t: t, v: v} -> %{"t" => t, "bytes_total" => v} end)
      |> Jason.encode!()

    chart_keys = Jason.encode!(["bytes_total"])

    top_talkers_json = encode_top_n(talkers)
    top_destinations_json = encode_top_n(destinations)
    # §37.3: the device is scoped by device_id: which matches BOTH directions, so
    # the talkers (src) and destinations (dst) widgets split each peer across two
    # lists. Merge them into one canonical per-peer ranking so a peer appears
    # once with its summed bidirectional volume — same canonicalization as the
    # dashboard's Top Conversations (#4202).
    top_peers_json =
      talkers
      |> merge_device_peers(destinations)
      |> encode_top_n()

    top_ports_json = encode_top_n(ports)
    top_protocols_json = encode_top_n(protocols)

    facets = %{
      protocols:
        Enum.map(protocols, fn row ->
          %{
            label: row[:name] || "unknown",
            value: row[:bytes] || 0,
            filter_value: row[:filter_value] || row[:name] || "unknown"
          }
        end),
      directions:
        Enum.map(directions, fn row ->
          %{label: row[:name] || "unknown", value: row[:bytes] || 0}
        end),
      services:
        services
        |> Enum.map(fn row ->
          %{label: row[:name] || "unknown", value: row[:bytes] || 0}
        end)
        |> Enum.reject(&(&1.label == "unknown"))
    }

    {summary, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_peers_json, top_ports_json, top_protocols_json, facets}
  end

  defp load_device_flow_summary(srql_mod, scope, base) do
    queries = [
      {"#{base} stats:sum(bytes_total) as total_bytes", :total_bytes, "total_bytes"},
      {"#{base} stats:sum(packets_total) as total_packets", :total_packets, "total_packets"},
      {"#{base} stats:count(*) as flow_count", :flow_count, "flow_count"},
      {"#{base} stats:count_distinct(src_endpoint_ip) as unique_talkers", :unique_talkers, "unique_talkers"}
    ]

    queries
    |> Enum.map(fn {q, key, alias_field} ->
      Task.async(fn -> {key, query_single_stat(srql_mod, scope, q, alias_field)} end)
    end)
    |> safe_yield_many(10_000)
  end

  defp query_single_stat(srql_mod, scope, query, alias_field) do
    srql_mod
    |> srql_results(query, scope)
    |> List.first()
    |> row_payload()
    |> flow_stat_number(alias_field)
  end

  defp load_device_flow_top_n(srql_mod, scope, base, group_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total by #{group_field} sort:bytes_total:desc limit:5"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        name: flow_stat_field(p, group_field),
        bytes: flow_stat_number(p, "bytes_total")
      }
    end)
  end

  defp load_device_flow_protocols(srql_mod, scope, base) do
    query =
      ~s|#{base} stats:"sum(bytes_total) as bytes_total by protocol_num, protocol_name" sort:bytes_total:desc limit:5|

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)
      protocol_num = flow_stat_field(p, "protocol_num")
      protocol_name = flow_stat_field(p, "protocol_name")

      %{
        name: protocol_label(protocol_num, protocol_name),
        filter_value: protocol_filter_value(protocol_num, protocol_name),
        bytes: flow_stat_number(p, "bytes_total")
      }
    end)
  end

  defp load_device_flow_timeseries(srql_mod, scope, base) do
    query = "#{base} bucket:5m agg:sum value_field:bytes_total"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results
        |> Enum.map(fn row ->
          raw_t = row["timestamp"] || row["bucket"] || row["time_bucket"]

          %{
            t: parse_timestamp_ms(raw_t),
            v: to_safe_number(row["value"] || row["bytes_total"] || 0)
          }
        end)
        |> Enum.reject(&is_nil(&1.t))

      _ ->
        []
    end
  end

  defp parse_timestamp_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp parse_timestamp_ms(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp parse_timestamp_ms(raw) when is_integer(raw), do: if(raw < 1_000_000_000_000, do: raw * 1000, else: raw)

  defp parse_timestamp_ms(raw) when is_float(raw) do
    ms = trunc(raw)
    if ms < 1_000_000_000_000, do: ms * 1000, else: ms
  end

  defp parse_timestamp_ms(raw) when is_binary(raw) do
    with :error <- parse_iso8601_ms(raw),
         :error <- parse_naive_iso8601_ms(raw),
         do: nil
  end

  defp parse_timestamp_ms(_), do: nil

  defp parse_iso8601_ms(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> :error
    end
  end

  defp parse_naive_iso8601_ms(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
      _ -> :error
    end
  end

  defp encode_top_n(rows) do
    rows
    |> Enum.take(5)
    |> Enum.map(fn row ->
      %{
        label: row[:name] || "unknown",
        value: row[:bytes] || 0,
        filter_value: row[:filter_value] || row[:name] || "unknown"
      }
    end)
    |> Jason.encode!()
  end

  # §37.3: merge the device's talkers (rows where the device was src) and
  # destinations (rows where it was dst) into one canonical per-peer ranking.
  # Because the device is scoped by device_id: which matches BOTH directions, a
  # peer appears in each list once; summing by peer IP folds the two directions
  # so a peer shows once with its total bidirectional volume.
  defp merge_device_peers(talkers, destinations) do
    (talkers ++ destinations)
    |> Enum.reject(fn row -> is_nil(row[:name]) or row[:name] == "" end)
    |> Enum.group_by(& &1[:name])
    |> Enum.map(fn {name, group} ->
      %{name: name, bytes: Enum.sum(Enum.map(group, &(&1[:bytes] || 0)))}
    end)
    |> Enum.sort_by(& &1[:bytes], :desc)
  end

  defp protocol_label(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      1 -> "ICMP"
      6 -> "TCP"
      17 -> "UDP"
      47 -> "GRE"
      50 -> "ESP"
      51 -> "AH"
      58 -> "ICMPv6"
      89 -> "OSPF"
      132 -> "SCTP"
      n when is_integer(n) -> normalized_protocol_name(protocol_name) || "proto #{n}"
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  defp protocol_filter_value(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      n when is_integer(n) -> Integer.to_string(n)
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  defp parse_protocol_num(n) when is_integer(n), do: n

  defp parse_protocol_num(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_protocol_num(_), do: nil

  defp normalized_protocol_name(name) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: nil, else: String.upcase(name)
  end

  defp normalized_protocol_name(_), do: nil

  defp flow_stat_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp row_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp row_payload(%{} = row), do: row
  defp row_payload(_), do: %{}

  defp srql_results(srql_mod, query, scope) do
    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> []
    end
  end

  defp flow_stat_number(payload, key) do
    case flow_stat_field(payload, key) do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp to_safe_number(n) when is_number(n), do: n
  defp to_safe_number(nil), do: 0

  defp to_safe_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_safe_number(_), do: 0

  defp safe_yield_many(tasks, timeout) do
    tasks
    |> Task.yield_many(timeout)
    |> Enum.reduce(%{}, fn {task, result}, acc ->
      key = task_key(task)

      case result do
        {:ok, {returned_key, value}} when is_atom(returned_key) ->
          Map.put(acc, returned_key, value)

        {:ok, value} when is_atom(key) ->
          Map.put(acc, key, value)

        _ ->
          Task.shutdown(task, :brutal_kill)
          acc
      end
    end)
  end

  defp task_key(%Task{ref: ref}) do
    Process.get({:flow_data_task_key, ref})
  end

  defp task_key(_), do: nil

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp default_flows_query(device_uid) do
    ~s|in:flows device_id:"#{escape_value(device_uid)}" time:last_24h sort:time:desc|
  end

  defp cheap_flow_presence(device_uid) when is_binary(device_uid) and device_uid != "" do
    with {:ok, ips} <- device_flow_ips(device_uid),
         {:ok, samplers} <- device_flow_samplers(device_uid),
         {:ok, ip_hit} <- any_present?(ips, &flow_seen_for_ip?/1),
         {:ok, sampler_hit} <- any_present?(samplers, &flow_seen_for_sampler?/1) do
      {:ok, ip_hit or sampler_hit}
    end
  rescue
    _ -> :error
  end

  defp cheap_flow_presence(_device_uid), do: {:ok, false}

  defp any_present?([], _fun), do: {:ok, false}

  defp any_present?([value | rest], fun) do
    case fun.(value) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> any_present?(rest, fun)
      :error -> :error
    end
  end

  defp device_flow_ips(device_uid) do
    case Repo.query(
           """
           SELECT d.ip
           FROM platform.ocsf_devices d
           WHERE d.uid = $1 AND d.ip IS NOT NULL AND d.ip <> ''
           UNION
           SELECT das.alias_value
           FROM platform.device_alias_states das
           WHERE das.device_id = $1
             AND das.alias_type = 'ip'
             AND das.state IN ('detected', 'confirmed', 'updated')
           """,
           [device_uid]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, rows |> Enum.map(&List.first/1) |> Enum.filter(&is_binary/1)}

      {:error, _reason} ->
        :error
    end
  end

  defp device_flow_samplers(device_uid) do
    case Repo.query(
           """
           SELECT sampler_address
           FROM platform.netflow_exporter_cache
           WHERE device_uid = $1
           """,
           [device_uid]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, rows |> Enum.map(&List.first/1) |> Enum.filter(&is_binary/1)}

      {:error, _reason} ->
        :error
    end
  end

  defp flow_seen_for_ip?(ip) do
    with {:ok, false} <-
           interpret_exists(fn ->
             Repo.query(
               """
               SELECT 1
               FROM platform.ocsf_network_activity
               WHERE time > now() - interval '24 hours' AND src_endpoint_ip = $1
               LIMIT 1
               """,
               [ip]
             )
           end) do
      interpret_exists(fn ->
        Repo.query(
          """
          SELECT 1
          FROM platform.ocsf_network_activity
          WHERE time > now() - interval '24 hours' AND dst_endpoint_ip = $1
          LIMIT 1
          """,
          [ip]
        )
      end)
    end
  end

  defp flow_seen_for_sampler?(sampler) do
    interpret_exists(fn ->
      Repo.query(
        """
        SELECT 1
        FROM platform.ocsf_network_activity
        WHERE time > now() - interval '24 hours' AND sampler_address = $1
        LIMIT 1
        """,
        [sampler]
      )
    end)
  end

  defp interpret_exists(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, _reason} -> :error
    end
  rescue
    _ -> :error
  end

  defp srql_flow_presence(srql_module, device_uid, scope) do
    query = ~s|in:flows device_id:"#{escape_value(device_uid)}" time:last_24h limit:1|

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [_ | _]}} -> true
      _ -> false
    end
  end
end
