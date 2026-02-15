defmodule ServiceRadar.BGP.Stats do
  @moduledoc """
  BGP statistics and analytics queries.

  Provides aggregate queries for BGP routing data analysis:
  - Traffic by AS number
  - Top BGP communities
  - AS path diversity metrics
  - AS topology graph data
  """

  require Ash.Query
  alias ServiceRadar.Repo

  @doc """
  Get traffic aggregated by AS number.

  Returns list of AS numbers with total bytes sorted by traffic volume.

  ## Parameters
    * `time_range` - Time window ("last_1h", "last_6h", "last_24h", "last_7d")
    * `source_protocol` - Optional filter by source ("netflow", "sflow", "bgp_peering")
    * `limit` - Maximum number of ASes to return (default: 10)

  ## Returns
    List of maps: `%{as_number: integer, bytes: integer, flow_count: integer}`
  """
  def get_traffic_by_as(time_range \\ "last_1h", source_protocol \\ nil, limit \\ 10) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    query = """
    SELECT
      unnest(as_path) as as_number,
      SUM(total_bytes)::bigint as bytes,
      SUM(flow_count)::integer as flow_count
    FROM platform.bgp_routing_info
    WHERE #{time_filter} #{protocol_filter}
    GROUP BY as_number
    ORDER BY bytes DESC
    LIMIT $#{length(params) + 1}
    """

    params = params ++ [limit]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [as_number, bytes, flow_count] ->
          %{
            as_number: as_number,
            bytes: bytes || 0,
            flow_count: flow_count || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get top BGP communities by traffic volume.

  Returns list of BGP communities with total bytes sorted by traffic.

  ## Parameters
    * `time_range` - Time window ("last_1h", "last_6h", "last_24h", "last_7d")
    * `source_protocol` - Optional filter by source
    * `limit` - Maximum number of communities to return (default: 10)

  ## Returns
    List of maps: `%{community: integer, bytes: integer, flow_count: integer}`
  """
  def get_top_communities(time_range \\ "last_1h", source_protocol \\ nil, limit \\ 10) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    query = """
    SELECT
      unnest(bgp_communities) as community,
      SUM(total_bytes)::bigint as bytes,
      SUM(flow_count)::integer as flow_count
    FROM platform.bgp_routing_info
    WHERE #{time_filter}
      AND bgp_communities IS NOT NULL
      #{protocol_filter}
    GROUP BY community
    ORDER BY bytes DESC
    LIMIT $#{length(params) + 1}
    """

    params = params ++ [limit]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [community, bytes, flow_count] ->
          %{
            community: community,
            bytes: bytes || 0,
            flow_count: flow_count || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get AS path diversity metrics.

  Returns statistics about AS path diversity including unique paths,
  average path length, and hop distribution.

  ## Parameters
    * `time_range` - Time window
    * `source_protocol` - Optional filter by source

  ## Returns
    Map with metrics:
    ```
    %{
      unique_paths: integer,
      avg_path_length: float,
      hop_distribution: %{2 => count, 3 => count, ...}
    }
    ```
  """
  def get_path_diversity(time_range \\ "last_1h", source_protocol \\ nil) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    # Query for unique paths and average length
    unique_query = """
    SELECT
      COUNT(DISTINCT as_path)::integer as unique_paths,
      AVG(array_length(as_path, 1))::float as avg_path_length
    FROM platform.bgp_routing_info
    WHERE #{time_filter} #{protocol_filter}
    """

    # Query for hop distribution
    hop_query = """
    SELECT
      array_length(as_path, 1) as hops,
      COUNT(*)::integer as count
    FROM platform.bgp_routing_info
    WHERE #{time_filter} #{protocol_filter}
    GROUP BY hops
    ORDER BY hops
    """

    with {:ok, %{rows: [[unique_paths, avg_length]]}} <- Repo.query(unique_query, params),
         {:ok, %{rows: hop_rows}} <- Repo.query(hop_query, params) do
      hop_distribution =
        Enum.into(hop_rows, %{}, fn [hops, count] -> {hops, count} end)

      %{
        unique_paths: unique_paths || 0,
        avg_path_length: avg_length || 0.0,
        hop_distribution: hop_distribution
      }
    else
      _ ->
        %{unique_paths: 0, avg_path_length: 0.0, hop_distribution: %{}}
    end
  end

  @doc """
  Get AS topology graph data (AS-to-AS connections).

  Returns edges for a network graph showing which ASes connect to which.
  Each edge represents adjacent ASes in observed paths with traffic volume.

  ## Parameters
    * `time_range` - Time window
    * `source_protocol` - Optional filter by source
    * `limit` - Maximum number of edges to return (default: 50)

  ## Returns
    List of edges: `%{from_as: integer, to_as: integer, bytes: integer}`
  """
  def get_as_topology(time_range \\ "last_1h", source_protocol \\ nil, limit \\ 50) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    # Extract adjacent AS pairs from paths using array slicing
    query = """
    WITH as_pairs AS (
      SELECT
        as_path[i] as from_as,
        as_path[i+1] as to_as,
        total_bytes
      FROM platform.bgp_routing_info,
           generate_series(1, array_length(as_path, 1) - 1) as i
      WHERE #{time_filter} #{protocol_filter}
    )
    SELECT
      from_as,
      to_as,
      SUM(total_bytes)::bigint as bytes
    FROM as_pairs
    GROUP BY from_as, to_as
    ORDER BY bytes DESC
    LIMIT $#{length(params) + 1}
    """

    params = params ++ [limit]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [from_as, to_as, bytes] ->
          %{
            from_as: from_as,
            to_as: to_as,
            bytes: bytes || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get detailed AS path information.

  Returns all unique AS paths with their traffic statistics.

  ## Parameters
    * `time_range` - Time window
    * `source_protocol` - Optional filter by source
    * `limit` - Maximum paths to return (default: 50)

  ## Returns
    List of maps: `%{as_path: [integer], path_length: integer, bytes: integer, packets: integer, flow_count: integer}`
  """
  def get_as_path_details(time_range \\ "last_1h", source_protocol \\ nil, limit \\ 50) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    query = """
    SELECT
      as_path,
      array_length(as_path, 1) as path_length,
      SUM(total_bytes)::bigint as bytes,
      SUM(total_packets)::bigint as packets,
      SUM(flow_count)::integer as flow_count
    FROM platform.bgp_routing_info
    WHERE #{time_filter} #{protocol_filter}
    GROUP BY as_path
    ORDER BY bytes DESC
    LIMIT $#{length(params) + 1}
    """

    params = params ++ [limit]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [as_path, path_length, bytes, packets, flow_count] ->
          %{
            as_path: as_path || [],
            path_length: path_length || 0,
            bytes: bytes || 0,
            packets: packets || 0,
            flow_count: flow_count || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get data source information (samplers reporting BGP data).

  Returns list of samplers/collectors with their contribution.

  ## Parameters
    * `time_range` - Time window

  ## Returns
    List of maps: `%{sampler_address: string, bytes: integer, flow_count: integer, observation_count: integer}`
  """
  def get_data_sources(time_range \\ "last_1h") do
    {time_filter, params} = build_time_filter(time_range)

    query = """
    SELECT
      metadata->>'sampler_address' as sampler_address,
      SUM(total_bytes)::bigint as bytes,
      SUM(flow_count)::integer as flow_count,
      COUNT(*)::integer as observation_count
    FROM platform.bgp_routing_info
    WHERE #{time_filter}
      AND metadata IS NOT NULL
      AND metadata->>'sampler_address' IS NOT NULL
    GROUP BY metadata->>'sampler_address'
    ORDER BY bytes DESC
    LIMIT 20
    """

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [sampler_address, bytes, flow_count, observation_count] ->
          %{
            sampler_address: sampler_address,
            bytes: bytes || 0,
            flow_count: flow_count || 0,
            observation_count: observation_count || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get traffic time series data for top ASes.

  Returns traffic over time bucketed by interval.

  ## Parameters
    * `time_range` - Time window
    * `source_protocol` - Optional filter by source
    * `top_n` - Number of top ASes to track (default: 5)

  ## Returns
    Map with keys: `:series` (list of AS numbers), `:data` (list of time buckets with values per AS)
  """
  def get_traffic_timeseries(time_range \\ "last_1h", source_protocol \\ nil, top_n \\ 5) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    # Determine bucket size based on time range
    bucket_size =
      case time_range do
        "last_1h" -> "1 minute"
        "last_6h" -> "5 minutes"
        "last_24h" -> "15 minutes"
        "last_7d" -> "1 hour"
        _ -> "5 minutes"
      end

    query = """
    WITH top_ases AS (
      SELECT as_path[1] as as_number
      FROM platform.bgp_routing_info
      WHERE #{time_filter} #{protocol_filter}
      GROUP BY as_path[1]
      ORDER BY SUM(total_bytes) DESC
      LIMIT $#{length(params) + 1}
    )
    SELECT
      time_bucket('#{bucket_size}', timestamp) as time_bucket,
      as_path[1] as as_number,
      SUM(total_bytes)::bigint as bytes
    FROM platform.bgp_routing_info
    WHERE #{time_filter}
      #{protocol_filter}
      AND as_path[1] IN (SELECT as_number FROM top_ases)
    GROUP BY time_bucket, as_path[1]
    ORDER BY time_bucket, as_number
    """

    params = params ++ [top_n]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        # Group by time bucket, then by AS
        grouped =
          Enum.group_by(rows, fn [time_bucket, _as, _bytes] -> time_bucket end)
          |> Enum.map(fn {time_bucket, entries} ->
            values = Map.new(entries, fn [_time, as_number, bytes] -> {as_number, bytes || 0} end)
            %{time: time_bucket, values: values}
          end)
          |> Enum.sort_by(& &1.time, DateTime)

        # Get unique AS numbers
        series =
          rows
          |> Enum.map(fn [_time, as_number, _bytes] -> as_number end)
          |> Enum.uniq()
          |> Enum.sort()

        %{series: series, data: grouped}

      {:error, _} ->
        %{series: [], data: []}
    end
  end

  @doc """
  Get prefix analysis (destination IP prefixes by AS).

  Groups destination IPs by /24 prefix and shows which AS serves them.

  ## Parameters
    * `time_range` - Time window
    * `source_protocol` - Optional filter by source
    * `limit` - Maximum prefixes to return (default: 20)

  ## Returns
    List of maps: `%{prefix: string, as_number: integer, bytes: integer, flow_count: integer}`
  """
  def get_prefix_analysis(time_range \\ "last_1h", source_protocol \\ nil, limit \\ 20) do
    {time_filter, params} = build_time_filter(time_range)

    protocol_filter =
      if source_protocol do
        "AND source_protocol = $#{length(params) + 1}"
      else
        ""
      end

    params = if source_protocol, do: params ++ [source_protocol], else: params

    query = """
    SELECT
      host(network(set_masklen(dst_ip::inet, 24))) || '/24' as prefix,
      as_path[1] as as_number,
      SUM(total_bytes)::bigint as bytes,
      SUM(flow_count)::integer as flow_count
    FROM platform.bgp_routing_info
    WHERE #{time_filter}
      #{protocol_filter}
      AND dst_ip IS NOT NULL
    GROUP BY prefix, as_path[1]
    ORDER BY bytes DESC
    LIMIT $#{length(params) + 1}
    """

    params = params ++ [limit]

    case Repo.query(query, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [prefix, as_number, bytes, flow_count] ->
          %{
            prefix: prefix,
            as_number: as_number,
            bytes: bytes || 0,
            flow_count: flow_count || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  # Private helper to build time filter SQL and params
  defp build_time_filter(time_range) do
    interval =
      case time_range do
        "last_1h" -> "1 hour"
        "last_6h" -> "6 hours"
        "last_24h" -> "24 hours"
        "last_7d" -> "7 days"
        _ -> "1 hour"
      end

    {"timestamp >= NOW() - INTERVAL '#{interval}'", []}
  end
end
