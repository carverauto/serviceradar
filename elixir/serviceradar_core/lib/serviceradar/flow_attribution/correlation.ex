defmodule ServiceRadar.FlowAttribution.Correlation do
  @moduledoc """
  One correlation pass: match recent unattributed flows to process attribution
  observations in the warehouse and publish the matches as attribution updates.

  The match runs as a single StarRocks statement over `ocsf_network_activity`
  and `flow_process_attribution_observations` (`correlation_sql/3`). Two small
  control-plane inputs come from CNPG first and are written into the statement
  as literals: registered agent node IPs (node-SNAT candidates) and public
  endpoint backends (public VIP candidates). The StarRocks client speaks the
  text protocol only, so "bound" here means rendered by `literal/1`, which
  escapes every string it writes.

  After the match, workload identity is looked up in CNPG by
  `(partition, agent_id, container_id)` for the matched rows only, each update
  takes the next `flow_attribution_update_version`, and the updates go out on
  `events.flow.attribution` for EventWriter's `FlowAttributionUpdates`.

  ## Candidate precedence

  Every candidate needs the flow's partition and protocol and an observation
  within `@correlation_skew_seconds` of the flow. Lower `match_rank` wins:

    * 0 - exact 5-tuple, either direction (TCP/UDP); ICMP local/remote address
      equality without ports, either direction
    * 1 - wildcard listener on the flow's local ip:port, either direction;
      relaxed UDP (local ip, remote ip and remote port), either direction
    * 2 - node-SNAT: an observation from the agent whose node IP is the flow
      endpoint, matching the remote side (ports for TCP/UDP, none for ICMP)
    * 3 + exposure rank - public VIP on the flow mapped to the observing
      backend socket (Gateway 0, LoadBalancer/ExternalIP 1, others 2)

  Within a rank an observation with a container id beats a host-only one, then
  the observation closest in time wins, then the newest.
  """

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.FlowAttribution

  @correlation_window_minutes 15
  @correlation_skew_seconds 900

  # Upper bound on flows considered per pass so one statement cannot grow with
  # flow volume. Newest-first so live attribution stays current; a backlog
  # drains over subsequent passes.
  @batch_limit 5_000

  @query_timeout_ms 120_000

  @flows_table "ocsf_network_activity"
  @observations_table "flow_process_attribution_observations"

  @public_endpoint_backends_sql """
  SELECT DISTINCT
    CASE upper(coalesce(pe.protocol, 'TCP'))
      WHEN 'TCP' THEN 6
      WHEN 'UDP' THEN 17
      WHEN 'SCTP' THEN 132
    END AS proto_num,
    lower(regexp_replace(pe.ip, '^::ffff:', '', 'i')) AS vip_ip_norm,
    pe.port AS vip_port,
    lower(regexp_replace(t->>'ip', '^::ffff:', '', 'i')) AS backend_ip_norm,
    (t->>'port')::integer AS backend_port,
    CASE lower(coalesce(pe.exposure_class, ''))
      WHEN 'gateway' THEN 0
      WHEN 'loadbalancer' THEN 1
      WHEN 'externalip' THEN 1
      ELSE 2
    END AS exposure_rank
  FROM platform.public_endpoints_current AS pe
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(pe.endpoint_targets) = 'array' THEN pe.endpoint_targets ELSE '[]'::jsonb END
  ) AS t
  WHERE pe.deleted_at IS NULL
    AND coalesce(pe.ip, '') <> ''
    AND pe.port IS NOT NULL
    AND upper(coalesce(pe.protocol, 'TCP')) IN ('TCP', 'UDP', 'SCTP')
    AND coalesce(t->>'ip', '') <> ''
    AND coalesce(t->>'port', '') ~ '^[0-9]{1,5}$'
  """

  @agent_ips_sql """
  SELECT uid, ip FROM platform.ocsf_agents WHERE coalesce(ip, '') <> '' AND coalesce(uid, '') <> ''
  """

  @workload_identity_sql """
  SELECT w.partition, w.agent_id, w.container_id, w.identity
  FROM platform.workload_identity_current AS w
  JOIN unnest($1::text[], $2::text[], $3::text[]) AS k(partition, agent_id, container_id)
    ON w.partition = k.partition AND w.agent_id = k.agent_id AND w.container_id = k.container_id
  """

  @versions_sql "SELECT nextval('platform.flow_attribution_update_version') FROM generate_series(1, $1)"

  @doc """
  Runs one pass. Returns the number of flows stamped, or `:not_applicable`
  when attribution is disabled because StarRocks is not configured.

  Options (tests): `:enabled`, `:query` (StarRocks, `sql -> result`),
  `:repo_query` (CNPG, `(sql, params) -> result`) and `:publish` (passed to
  `Attribution.publish_updates/2`).
  """
  @spec correlate(keyword()) :: {:ok, non_neg_integer() | :not_applicable} | {:error, term()}
  def correlate(opts \\ []), do: opts |> run_pass() |> elem(0)

  @doc """
  Runs one pass like `correlate/1` and also returns the matches it found per
  `match_rank` (empty when the pass failed before matching), for `PassMetrics`.
  """
  @spec run_pass(keyword()) ::
          {{:ok, non_neg_integer() | :not_applicable} | {:error, term()},
           %{non_neg_integer() => non_neg_integer()}}
  def run_pass(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &FlowAttribution.enabled?/0) do
      run(opts)
    else
      {{:ok, :not_applicable}, %{}}
    end
  end

  defp run(opts) do
    repo_query = Keyword.get(opts, :repo_query, &repo_query/2)
    query = Keyword.get(opts, :query, &Query.execute(&1, timeout: @query_timeout_ms))

    with {:ok, agent_ips} <- rows(repo_query.(@agent_ips_sql, [])),
         {:ok, backends} <- rows(repo_query.(@public_endpoint_backends_sql, [])),
         sql = correlation_sql(agent_ips, backends),
         {:ok, matches} <- maps(query.(sql)) do
      by_rank = Enum.frequencies_by(matches, &to_integer(&1["match_rank"]))

      result =
        with {:ok, matches} <- with_workload_identity(matches, repo_query),
             {:ok, updates} <- with_versions(matches, repo_query),
             :ok <- Attribution.publish_updates(updates, opts) do
          {:ok, length(updates)}
        end

      {result, by_rank}
    else
      {:error, _reason} = error -> {error, %{}}
    end
  end

  defp repo_query(sql, params),
    do: ServiceRadar.Repo.query(sql, params, timeout: @query_timeout_ms)

  defp rows({:ok, %{rows: rows}}), do: {:ok, rows}
  defp rows({:error, _reason} = error), do: error

  defp maps({:ok, %{columns: columns, rows: rows}}),
    do: {:ok, Enum.map(rows, &Map.new(Enum.zip(columns, &1)))}

  defp maps({:error, _reason} = error), do: error

  @doc "How far back the pass reads unattributed flows, in minutes."
  @spec flows_window_minutes() :: pos_integer()
  def flows_window_minutes, do: @correlation_window_minutes

  @doc "How far back the pass reads observations (window plus skew), in seconds."
  @spec observations_window_seconds() :: pos_integer()
  def observations_window_seconds,
    do: @correlation_window_minutes * 60 + @correlation_skew_seconds

  @doc "The most flows one pass reads."
  @spec batch_limit() :: pos_integer()
  def batch_limit, do: @batch_limit

  @doc """
  The correlation statement.

  `agent_ips` is `[[agent_id, ip]]` and `backends` is
  `[[proto_num, vip_ip_norm, vip_port, backend_ip_norm, backend_port, exposure_rank]]`,
  as read from CNPG. Rows that are not well formed are left out. An empty input
  leaves its candidate families out of the statement.

  Options: `:flows_table` and `:observations_table` (qualified names; default
  the configured warehouse tables), `:batch_limit`.
  """
  @spec correlation_sql([list()], [list()], keyword()) :: String.t()
  def correlation_sql(agent_ips, backends, opts \\ []) do
    flows_table = Keyword.get_lazy(opts, :flows_table, fn -> Env.table(@flows_table) end)

    observations_table =
      Keyword.get_lazy(opts, :observations_table, fn -> Env.table(@observations_table) end)

    batch_limit = Keyword.get(opts, :batch_limit, @batch_limit)
    agent_values = values(agent_ips, &agent_ip_row/1)
    backend_values = values(backends, &backend_row/1)

    ctes =
      Enum.reject(
        [
          recent_flows_cte(flows_table, batch_limit),
          observations_cte(observations_table),
          agent_values && "agent_ips AS (SELECT * FROM (#{agent_values}) AS t(agent_id, ip))",
          backend_values &&
            "endpoint_backends AS (SELECT * FROM (#{backend_values}) AS " <>
              "t(proto_num, vip_ip_norm, vip_port, backend_ip_norm, backend_port, exposure_rank))",
          "candidates AS (\n#{Enum.join(candidate_branches(agent_values, backend_values), "\nUNION ALL\n")}\n)",
          """
          ranked AS (
            SELECT c.*,
                   ROW_NUMBER() OVER (
                     PARTITION BY c.id
                     ORDER BY c.match_rank, c.container_id IS NULL, c.time_delta_seconds,
                              c.observed_at DESC, c.agent_id, c.pid
                   ) AS rn
            FROM candidates AS c
          )
          """
        ],
        &is_nil/1
      )

    """
    WITH #{Enum.join(ctes, ",\n")}
    SELECT id, `time`, attribution_version, `partition`, agent_id, pid, comm, cmdline,
           container_id, workload_identity, match_rank
    FROM ranked
    WHERE rn = 1 AND pid IS NOT NULL
    """
  end

  defp recent_flows_cte(table, batch_limit) do
    """
    recent_flows AS (
      SELECT id, `time`, `partition`, protocol_num, attribution_version,
             src_endpoint_ip, dst_endpoint_ip, src_endpoint_port, dst_endpoint_port,
             #{ip_norm("src_endpoint_ip")} AS src_norm,
             #{ip_norm("dst_endpoint_ip")} AS dst_norm
      FROM #{table}
      WHERE `time` > DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{@correlation_window_minutes} MINUTE)
        AND pid IS NULL
      ORDER BY `time` DESC, id DESC
      LIMIT #{batch_limit}
    )
    """
  end

  # Observations older than the window plus skew cannot match any flow the
  # pass reads, and the bound prunes the scan to the newest daily partitions.
  defp observations_cte(table) do
    """
    observations AS (
      SELECT observed_at, `partition`, agent_id, proto, local_ip, local_port, remote_ip,
             remote_port, pid, comm, cmdline, container_id, workload_identity,
             #{ip_norm("local_ip")} AS local_norm,
             #{ip_norm("remote_ip")} AS remote_norm
      FROM #{table}
      WHERE observed_at > DATE_SUB(UTC_TIMESTAMP(),
                                   INTERVAL #{@correlation_window_minutes * 60 + @correlation_skew_seconds} SECOND)
    )
    """
  end

  defp ip_norm(column), do: "regexp_replace(lower(coalesce(#{column}, '')), '^::ffff:', '')"

  @not_icmp "a.proto NOT IN (1, 58)"
  @icmp "a.proto IN (1, 58)"
  @wildcard_remote "a.remote_port = 0 AND a.remote_ip IN ('0.0.0.0', '::')"

  defp candidate_branches(agent_values, backend_values) do
    local = [
      # Exact 5-tuple, both directions.
      {0, [],
       [
         @not_icmp,
         "a.local_ip = f.src_endpoint_ip",
         "a.remote_ip = f.dst_endpoint_ip",
         "a.local_port = f.src_endpoint_port",
         "a.remote_port = f.dst_endpoint_port"
       ]},
      {0, [],
       [
         @not_icmp,
         "a.local_ip = f.dst_endpoint_ip",
         "a.remote_ip = f.src_endpoint_ip",
         "a.local_port = f.dst_endpoint_port",
         "a.remote_port = f.src_endpoint_port"
       ]},
      # Wildcard listener on the local ip:port, both directions.
      {1, [],
       [
         @not_icmp,
         @wildcard_remote,
         "a.local_ip = f.src_endpoint_ip",
         "a.local_port = f.src_endpoint_port"
       ]},
      {1, [],
       [
         @not_icmp,
         @wildcard_remote,
         "a.local_ip = f.dst_endpoint_ip",
         "a.local_port = f.dst_endpoint_port"
       ]},
      # ICMP has no ports: address equality only, both directions.
      {0, [], [@icmp, "a.local_ip = f.src_endpoint_ip", "a.remote_ip = f.dst_endpoint_ip"]},
      {0, [], [@icmp, "a.local_ip = f.dst_endpoint_ip", "a.remote_ip = f.src_endpoint_ip"]},
      # Relaxed UDP: the exporter's local port may differ (or be coalesced to 0).
      {1, [],
       [
         "f.protocol_num = 17",
         "a.remote_port > 0",
         "a.local_ip = f.src_endpoint_ip",
         "a.remote_ip = f.dst_endpoint_ip",
         "a.remote_port = f.dst_endpoint_port"
       ]},
      {1, [],
       [
         "f.protocol_num = 17",
         "a.remote_port > 0",
         "a.local_ip = f.dst_endpoint_ip",
         "a.remote_ip = f.src_endpoint_ip",
         "a.remote_port = f.src_endpoint_port"
       ]}
    ]

    snat =
      if agent_values do
        node = fn side -> "JOIN agent_ips AS ag ON ag.ip = f.#{side}_endpoint_ip" end

        [
          {2, [node.("src")],
           [
             @not_icmp,
             "a.agent_id = ag.agent_id",
             "a.local_ip <> ag.ip",
             "a.remote_ip = f.dst_endpoint_ip",
             "a.remote_port = f.dst_endpoint_port"
           ]},
          {2, [node.("dst")],
           [
             @not_icmp,
             "a.agent_id = ag.agent_id",
             "a.local_ip <> ag.ip",
             "a.remote_ip = f.src_endpoint_ip",
             "a.remote_port = f.src_endpoint_port"
           ]},
          {2, [node.("src")],
           [
             @icmp,
             "a.agent_id = ag.agent_id",
             "a.local_ip <> ag.ip",
             "a.remote_ip = f.dst_endpoint_ip"
           ]},
          {2, [node.("dst")],
           [
             @icmp,
             "a.agent_id = ag.agent_id",
             "a.local_ip <> ag.ip",
             "a.remote_ip = f.src_endpoint_ip"
           ]}
        ]
      else
        []
      end

    public =
      if backend_values do
        [public_vip_branch("dst", "src"), public_vip_branch("src", "dst")]
      else
        []
      end

    Enum.map(local ++ snat ++ public, &branch_sql/1)
  end

  # A public VIP on one side of the flow mapped to the backend socket that
  # served it; the socket's peer is the flow's other side or a wildcard.
  defp public_vip_branch(vip_side, peer_side) do
    {"3 + pe.exposure_rank",
     [
       """
       JOIN endpoint_backends AS pe
         ON pe.proto_num = f.protocol_num
        AND pe.vip_ip_norm = f.#{vip_side}_norm
        AND pe.vip_port = f.#{vip_side}_endpoint_port
       """
     ],
     [
       @not_icmp,
       "a.local_norm = pe.backend_ip_norm",
       "a.local_port = pe.backend_port",
       "((#{@wildcard_remote}) OR (a.remote_norm = f.#{peer_side}_norm AND " <>
         "(a.remote_port = f.#{peer_side}_endpoint_port OR a.remote_port = 0)))"
     ]}
  end

  defp branch_sql({rank, joins, conditions}) do
    """
    SELECT f.id, f.`time`, f.attribution_version, f.`partition`, a.agent_id, a.pid, a.comm,
           a.cmdline, a.container_id, a.workload_identity, #{rank} AS match_rank,
           abs(seconds_diff(f.`time`, a.observed_at)) AS time_delta_seconds, a.observed_at
    FROM recent_flows AS f
    #{Enum.join(joins, "\n")}
    JOIN observations AS a
      ON a.`partition` = f.`partition` AND a.proto = f.protocol_num
    WHERE a.observed_at BETWEEN f.`time` - INTERVAL #{@correlation_skew_seconds} SECOND
                            AND f.`time` + INTERVAL #{@correlation_skew_seconds} SECOND
      AND #{Enum.join(conditions, "\n  AND ")}
    """
  end

  defp values(rows, row_fun) do
    case rows |> Enum.map(row_fun) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> nil
      literals -> "VALUES " <> Enum.map_join(literals, ", ", &"(#{Enum.join(&1, ", ")})")
    end
  end

  defp agent_ip_row([agent_id, ip]) when is_binary(agent_id) and is_binary(ip),
    do: [literal(agent_id), literal(ip)]

  defp agent_ip_row(_row), do: nil

  defp backend_row([proto, vip_ip, vip_port, backend_ip, backend_port, rank])
       when is_integer(proto) and is_binary(vip_ip) and is_integer(vip_port) and
              is_binary(backend_ip) and
              is_integer(backend_port) and is_integer(rank) do
    [proto, literal(vip_ip), vip_port, literal(backend_ip), backend_port, rank]
  end

  defp backend_row(_row), do: nil

  @doc """
  A StarRocks string literal. Backslash is the escape character in StarRocks
  (MySQL) string literals, so it is escaped before the quote.
  """
  @spec literal(String.t()) :: String.t()
  def literal(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'" <> escaped <> "'"
  end

  # Workload identity from the observation wins over the standalone snapshot,
  # which only fills what the observation left out.
  defp with_workload_identity(matches, repo_query) do
    keys =
      for %{"container_id" => container_id} = match <- matches,
          is_binary(container_id) and container_id != "",
          uniq: true,
          do: {match["partition"], match["agent_id"], container_id}

    case lookup_workload_identity(keys, repo_query) do
      {:ok, identities} ->
        {:ok,
         Enum.map(matches, fn match ->
           key = {match["partition"], match["agent_id"], match["container_id"]}
           standalone = Map.get(identities, key) || %{}
           observed = decode_identity(match["workload_identity"]) || %{}

           Map.put(match, "workload_identity", empty_to_nil(Map.merge(standalone, observed)))
         end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp lookup_workload_identity([], _repo_query), do: {:ok, %{}}

  defp lookup_workload_identity(keys, repo_query) do
    {partitions, agents, containers} =
      Enum.reduce(Enum.reverse(keys), {[], [], []}, fn {p, a, c}, {ps, as, cs} ->
        {[p | ps], [a | as], [c | cs]}
      end)

    with {:ok, rows} <-
           rows(repo_query.(@workload_identity_sql, [partitions, agents, containers])) do
      {:ok,
       Map.new(rows, fn [partition, agent_id, container_id, identity] ->
         {{partition, agent_id, container_id}, decode_identity(identity)}
       end)}
    end
  end

  defp decode_identity(identity) when is_map(identity), do: identity

  defp decode_identity(identity) when is_binary(identity) and identity != "" do
    case Jason.decode(identity) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp decode_identity(_identity), do: nil

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  # A stamp's version must exceed the flow's stored version and every version
  # handed out before it, so a later pass always supersedes an earlier one.
  defp with_versions([], _repo_query), do: {:ok, []}

  defp with_versions(matches, repo_query) do
    with {:ok, rows} <- rows(repo_query.(@versions_sql, [length(matches)])) do
      {:ok,
       matches
       |> Enum.zip(rows)
       |> Enum.map(fn {match, [next]} ->
         stored = to_integer(match["attribution_version"])
         Map.put(match, "attribution_version", max(stored + 1, next))
       end)}
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
  defp to_integer(_value), do: 0
end
