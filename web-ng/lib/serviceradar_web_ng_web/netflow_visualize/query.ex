defmodule ServiceRadarWebNGWeb.NetflowVisualize.Query do
  @moduledoc false

  require Logger

  # Keep these helpers small and SRQL-first. They intentionally do not touch Ecto.

  @allowed_downsample_series_dims ~w(
    protocol_group
    app
    dst_port
    src_ip
    dst_ip
    protocol_name
    sampler_address
  )

  def flows_base_query(query, fallback_time) when is_binary(query) and is_binary(fallback_time) do
    q =
      query
      |> String.trim()
      |> ensure_prefix("in:flows")
      |> strip_tokens(["sort", "cursor"])

    q =
      if Regex.match?(~r/(?:^|\s)time:(?:"[^"]+"|\S+)/, q) do
        q
      else
        String.trim(q <> " time:" <> fallback_time)
      end

    q
  end

  def flows_base_query(_query, fallback_time), do: "in:flows time:" <> fallback_time

  def flows_sanitize_for_stats(query) when is_binary(query) do
    # Stats queries should control their own limit/sort, and we don't want downsample tokens.
    strip_tokens(query, [
      "limit",
      "sort",
      "bucket",
      "agg",
      "value_field",
      "series",
      "stats",
      "rollup_stats"
    ])
  end

  def flows_sanitize_for_stats(other), do: to_string(other || "")

  def downsample_series_field_from_dims(dims) do
    dims
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.find("protocol_group", fn d -> Enum.member?(@allowed_downsample_series_dims, d) end)
    |> downsample_series_field_from_dim()
  end

  def downsample_series_field_from_dim("dst_port"), do: "dst_port"
  def downsample_series_field_from_dim("src_ip"), do: "src_ip"
  def downsample_series_field_from_dim("dst_ip"), do: "dst_ip"
  def downsample_series_field_from_dim("protocol_name"), do: "protocol_name"
  def downsample_series_field_from_dim("sampler_address"), do: "sampler_address"
  def downsample_series_field_from_dim("app"), do: "app"
  def downsample_series_field_from_dim("protocol_group"), do: "protocol_group"
  def downsample_series_field_from_dim(_), do: "protocol_group"

  def top_n(keys, points, limit, limit_type)
      when is_list(keys) and is_list(points) and is_integer(limit) and limit > 0 and
             limit_type in ["avg", "max", "last"] do
    series_scores =
      keys
      |> Enum.map(fn k -> {k, series_score(points, k, limit_type)} end)
      |> Enum.sort_by(fn {_k, score} -> -score end)

    top_keys =
      series_scores
      |> Enum.take(limit)
      |> Enum.map(fn {k, _} -> k end)

    if length(keys) <= length(top_keys) do
      {top_keys, points}
    else
      other_keys = MapSet.new(keys -- top_keys)

      points =
        Enum.map(points, &bucket_other_keys(&1, other_keys))

      {top_keys ++ ["Other"], points}
    end
  end

  def top_n(keys, points, _limit, _limit_type), do: {keys, points}

  def scale_points(points, scale_fun) when is_list(points) and is_function(scale_fun, 1) do
    Enum.map(points, fn
      %{"t" => _} = point ->
        Enum.reduce(point, point, fn
          {"t", _}, acc -> acc
          {k, v}, acc when is_binary(k) -> Map.put(acc, k, scale_fun.(v))
          _, acc -> acc
        end)

      other ->
        other
    end)
  end

  def load_downsample_series(srql_module, base_query, scope, opts \\ []) do
    bucket = Keyword.get(opts, :bucket, "5m")
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)

    q =
      base_query
      |> strip_tokens(["sort", "limit", "cursor", "stats", "rollup_stats"])
      |> then(fn q ->
        String.trim(
          q <>
            " bucket:" <>
            bucket <>
            " agg:" <>
            agg <>
            " value_field:" <>
            value_field <>
            " series:" <>
            series_field <>
            " limit:" <> Integer.to_string(limit)
        )
      end)

    rows =
      case apply(srql_module, :query, [q, %{scope: scope}]) do
        {:ok, %{"results" => results}} when is_list(results) ->
          results

        {:error, reason} ->
          Logger.warning("NetFlow downsample query failed: #{inspect(reason)}")
          []

        _ ->
          []
      end

    {keys, buckets} =
      Enum.reduce(rows, {MapSet.new(), %{}}, fn
        %{"timestamp" => ts, "series" => series, "value" => value}, {keys, acc} ->
          with {:ok, dt} <- parse_srql_datetime(ts),
               true <- is_binary(series) and series != "",
               v when is_number(v) <- to_number(value) do
            keys = MapSet.put(keys, series)

            acc =
              Map.update(acc, dt, %{series => v}, fn m ->
                Map.update(m, series, v, &(&1 + v))
              end)

            {keys, acc}
          else
            _ -> {keys, acc}
          end

        _row, acc ->
          acc
      end)

    keys = keys |> MapSet.to_list() |> Enum.sort()

    points =
      buckets
      |> Enum.sort_by(fn {dt, _} -> DateTime.to_unix(dt, :second) end)
      |> Enum.map(fn {dt, values} ->
        base = %{"t" => DateTime.to_iso8601(dt)}

        Enum.reduce(keys, base, fn k, acc ->
          Map.put(acc, k, Map.get(values, k, 0))
        end)
      end)

    {keys, points}
  rescue
    _ -> {[], []}
  end

  def load_sankey(srql_module, base_query, scope, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix, 24)
    dims = Keyword.get(opts, :dims, [])
    max_edges = Keyword.get(opts, :max_edges, 200)

    group_bys = sankey_group_bys(dims, prefix)

    load_sankey(srql_module, base_query, scope, prefix,
      group_bys: group_bys,
      max_edges: max_edges
    )
  end

  def load_sankey(srql_module, base_query, scope, prefix) when prefix in [16, 24, 32] do
    load_sankey(srql_module, base_query, scope, prefix, group_bys: nil, max_edges: 200)
  end

  def load_sankey(_srql_module, _base_query, _scope, _prefix),
    do: %{edges: [], sources: [], mids: [], dests: []}

  def load_sankey(srql_module, base_query, scope, prefix, opts)
      when prefix in [16, 24, 32] and is_list(opts) do
    base_query =
      base_query
      |> flows_sanitize_for_stats()
      |> String.trim()

    cidr_prefix = cidr_prefix_for(prefix)
    group_bys = group_bys_from_opts(opts, cidr_prefix)
    max_edges = Keyword.get(opts, :max_edges, 200)

    cidr_query = sankey_stats_query(base_query, group_bys, max_edges)
    ip_query = sankey_ip_fallback_query(base_query, max_edges)

    {rows, mode} = sankey_rows_and_mode(srql_module, scope, cidr_query, ip_query)

    edges =
      rows
      |> sankey_edges(mode)
      |> Enum.filter(&valid_edge?/1)
      |> Enum.take(max_edges)

    sankey_result(edges)
  rescue
    _ ->
      %{edges: [], sources: [], mids: [], dests: []}
  end

  defp sum_edges_by(edges, field) do
    edges
    |> Enum.reduce(%{}, fn e, acc ->
      key = Map.get(e, field)
      bytes = Map.get(e, :bytes, 0)

      if is_binary(key) and key != "" and is_integer(bytes) and bytes > 0 do
        Map.update(acc, key, bytes, &(&1 + bytes))
      else
        acc
      end
    end)
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(12)
  end

  defp srql_stats_rows(srql_module, query, scope, label)
       when is_binary(query) and is_binary(label) do
    case apply(srql_module, :query, [query, %{scope: scope}]) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results

      {:ok, _} = ok ->
        extract_stats_rows(ok)

      {:error, reason} ->
        Logger.warning("NetFlow sankey #{label} query failed: #{inspect(reason)}")
        []

      other ->
        Logger.warning("NetFlow sankey #{label} query unexpected result: #{inspect(other)}")
        []
    end
  end

  defp extract_stats_rows({:ok, %{"results" => results}}) when is_list(results), do: results
  defp extract_stats_rows(_), do: []

  defp sankey_edge_cidr(row) do
    src = Map.get(row, "src_cidr")
    dst = Map.get(row, "dst_cidr")
    port = to_int(Map.get(row, "dst_endpoint_port"))
    bytes = to_int(Map.get(row, "total_bytes"))
    mid = port_mid_label(port)
    %{src: src, mid: mid, port: port, dst: dst, bytes: bytes}
  end

  defp sankey_edge_ip(row) do
    src = Map.get(row, "src_endpoint_ip")
    dst = Map.get(row, "dst_endpoint_ip")
    port = to_int(Map.get(row, "dst_endpoint_port"))
    bytes = to_int(Map.get(row, "total_bytes"))
    mid = port_mid_label(port)
    %{src: src, mid: mid, port: port, dst: dst, bytes: bytes}
  end

  defp sankey_group_bys(dims, prefix) when prefix in [16, 24, 32] do
    cidr_prefix =
      case prefix do
        32 -> 24
        other -> other
      end

    dims =
      dims
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    src = dims |> Enum.at(0) |> sankey_dim_to_group_by(:src, cidr_prefix)
    mid = dims |> Enum.at(1) |> sankey_dim_to_group_by(:mid, cidr_prefix)
    dst = dims |> Enum.at(2) |> sankey_dim_to_group_by(:dst, cidr_prefix)

    [src, mid, dst]
  end

  defp sankey_group_bys(_dims, prefix) when prefix in [16, 24, 32] do
    cidr_prefix = if prefix == 32, do: 24, else: prefix
    ["src_cidr:#{cidr_prefix}", "dst_endpoint_port", "dst_cidr:#{cidr_prefix}"]
  end

  defp sankey_dim_to_group_by(dim, :src, cidr_prefix) do
    case dim do
      "src_ip" -> "src_endpoint_ip"
      "src_cidr" -> "src_cidr:#{cidr_prefix}"
      _ -> "src_cidr:#{cidr_prefix}"
    end
  end

  defp sankey_dim_to_group_by(dim, :dst, cidr_prefix) do
    case dim do
      "dst_ip" -> "dst_endpoint_ip"
      "dst_cidr" -> "dst_cidr:#{cidr_prefix}"
      _ -> "dst_cidr:#{cidr_prefix}"
    end
  end

  defp sankey_dim_to_group_by(dim, :mid, _cidr_prefix) do
    case dim do
      "dst_port" -> "dst_endpoint_port"
      "app" -> "app"
      "protocol_group" -> "protocol_group"
      _ -> "dst_endpoint_port"
    end
  end

  defp port_mid_label(port) when is_integer(port) and port > 0 do
    case port do
      53 -> "dns"
      80 -> "http"
      443 -> "https"
      22 -> "ssh"
      123 -> "ntp"
      p when p < 1024 -> "port:" <> Integer.to_string(p)
      _ -> "high-port"
    end
  end

  defp port_mid_label(_), do: "port:unknown"

  defp cidr_prefix_for(32), do: 24
  defp cidr_prefix_for(other), do: other

  defp group_bys_from_opts(opts, cidr_prefix) when is_list(opts) and is_integer(cidr_prefix) do
    case Keyword.get(opts, :group_bys) do
      g when is_list(g) and length(g) == 3 -> g
      _ -> ["src_cidr:#{cidr_prefix}", "dst_endpoint_port", "dst_cidr:#{cidr_prefix}"]
    end
  end

  defp sankey_stats_query(base_query, group_bys, max_edges)
       when is_binary(base_query) and is_list(group_bys) and is_integer(max_edges) do
    ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by #{Enum.join(group_bys, ", ")}" sort:total_bytes:desc limit:#{max_edges}|
  end

  defp sankey_ip_fallback_query(base_query, max_edges)
       when is_binary(base_query) and is_integer(max_edges) do
    ~s|#{base_query} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip, dst_endpoint_port, dst_endpoint_ip" sort:total_bytes:desc limit:#{max_edges}|
  end

  defp sankey_rows_and_mode(srql_module, scope, cidr_query, ip_query) do
    cidr_rows = srql_stats_rows(srql_module, cidr_query, scope, "CIDR")

    if cidr_rows == [] do
      {srql_stats_rows(srql_module, ip_query, scope, "IP"), :ip}
    else
      {cidr_rows, :cidr}
    end
  end

  defp sankey_edges(rows, mode) when is_list(rows) and mode in [:cidr, :ip] do
    edge_fun =
      case mode do
        :cidr -> &sankey_edge_cidr/1
        :ip -> &sankey_edge_ip/1
      end

    Enum.map(rows, edge_fun)
  end

  defp sankey_edges(_rows, _mode), do: []

  defp valid_edge?(%{src: src, dst: dst, bytes: bytes})
       when is_binary(src) and is_binary(dst) and is_integer(bytes) do
    src not in ["", "Unknown"] and dst not in ["", "Unknown"] and bytes > 0
  end

  defp valid_edge?(_), do: false

  defp sankey_result(edges) when is_list(edges) do
    %{
      edges: edges,
      sources: sum_edges_by(edges, :src),
      mids: sum_edges_by(edges, :mid),
      dests: sum_edges_by(edges, :dst)
    }
  end

  defp bucket_other_keys(%{} = point, %MapSet{} = other_keys) do
    {other_sum, point} =
      Enum.reduce(other_keys, {0.0, point}, fn k, {sum, acc} ->
        {sum + to_number(Map.get(acc, k, 0)), Map.delete(acc, k)}
      end)

    Map.put(point, "Other", other_sum)
  end

  defp bucket_other_keys(other, _other_keys), do: other

  defp ensure_prefix(query, prefix) do
    q = String.trim(query)
    if String.starts_with?(q, prefix), do: q, else: prefix <> " " <> q
  end

  defp strip_tokens(query, tokens) when is_binary(query) and is_list(tokens) do
    Enum.reduce(tokens, query, fn token, acc ->
      # token:<value> or token:"value"
      Regex.replace(~r/(?:^|\s)#{Regex.escape(token)}:(?:"[^"]*"|\[[^\]]*\]|\S+)/, acc, "")
    end)
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp parse_srql_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> {:error, :invalid_timestamp}
        end
    end
  end

  defp parse_srql_datetime(_), do: {:error, :invalid_timestamp}

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} -> f
      _ -> 0
    end
  end

  defp to_number(_), do: 0

  defp series_score(points, key, "avg") do
    {sum, n} =
      Enum.reduce(points, {0.0, 0}, fn point, {acc, count} ->
        v = to_number(Map.get(point, key, 0))
        {acc + v, count + 1}
      end)

    if n == 0, do: 0.0, else: sum / n
  end

  defp series_score(points, key, "max") do
    Enum.reduce(points, 0.0, fn point, acc ->
      v = to_number(Map.get(point, key, 0))
      if v > acc, do: v, else: acc
    end)
  end

  defp series_score(points, key, "last") do
    case List.last(points) do
      %{} = point -> to_number(Map.get(point, key, 0))
      _ -> 0.0
    end
  end

  defp series_score(_points, _key, _), do: 0.0

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
