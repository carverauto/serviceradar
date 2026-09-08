defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrData do
  @moduledoc false

  import Ash.Expr

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrSettings
  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadar.Repo

  require Ash.Query

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_pending_states [:queued, :sent, :acknowledged, :running]
  @default_sort {"time", "DESC"}
  @allowed_sort_fields %{
    "time" => "time",
    "target" => "target",
    "target_ip" => "target_ip",
    "agent_id" => "agent_id",
    "protocol" => "protocol",
    "total_hops" => "total_hops",
    "target_reached" => "target_reached"
  }
  @allowed_filter_fields MapSet.new([
                           "target",
                           "target_ip",
                           "agent_id",
                           "protocol",
                           "check_name",
                           "device_id",
                           "target_reached",
                           "error"
                         ])
  @boolean_filter_fields MapSet.new(["target_reached"])
  @exact_filter_fields MapSet.new(["protocol", "device_id", "target_reached"])
  @safe_filter_columns %{
    "target" => "target",
    "target_ip" => "target_ip",
    "agent_id" => "agent_id",
    "protocol" => "protocol",
    "check_name" => "check_name",
    "device_id" => "device_id::text",
    "target_reached" => "target_reached",
    "error" => "error"
  }

  @sobelow_skip ["SQL.Query"]
  def list_traces(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    limit = normalize_limit(Keyword.get(opts, :limit, 50))

    {where_clause, params} = build_trace_where(target_filter, agent_filter, device_uid, device_ip)

    query = """
    WITH selected_traces AS (
      SELECT id, time, agent_id, check_id, check_name, device_id, target, target_ip,
             target_reached, total_hops, protocol, ip_version, error
      FROM mtr_traces
      #{where_clause}
      ORDER BY time DESC, id DESC
      LIMIT $#{length(params) + 1}
    ),
    terminal_hops AS (
      SELECT trace_id, sent, received, avg_us
      FROM (
        SELECT h.trace_id, h.sent, h.received, h.avg_us,
               ROW_NUMBER() OVER (
                 PARTITION BY h.trace_id
                 ORDER BY h.time DESC, h.id DESC
               ) AS terminal_rank
        FROM mtr_hops h
        INNER JOIN selected_traces st
          ON st.id = h.trace_id
          AND st.target_reached
          AND h.hop_number = st.total_hops
      ) ranked_terminal_hops
      WHERE terminal_rank = 1
    )
    SELECT st.id::text AS id, st.time, st.agent_id, st.check_id, st.check_name, st.device_id,
           st.target, st.target_ip, st.target_reached, st.total_hops, st.protocol, st.ip_version,
           st.error, destination.sent AS destination_sent,
           destination.received AS destination_received,
           destination.avg_us AS destination_avg_us,
             CASE
             WHEN destination.sent > 0 THEN
               (100.0 * (destination.sent - destination.received) / destination.sent)::float
           END AS destination_loss_pct
    FROM selected_traces st
    LEFT JOIN terminal_hops destination ON destination.trace_id = st.id
    ORDER BY st.time DESC, st.id DESC
    """

    case Repo.query(query, params ++ [limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["SQL.Query"]
  def list_traces_paginated(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    srql_query = normalize_string(Keyword.get(opts, :srql_query, ""))
    page = normalize_page(Keyword.get(opts, :page, 1))
    per_page = normalize_limit(Keyword.get(opts, :limit, default_history_page_size()))

    {where_clause, params, srql_sort} =
      build_trace_where_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query)

    {sort_field, sort_dir} = srql_sort || @default_sort
    order_clause = order_clause(sort_field, sort_dir)
    offset = (page - 1) * per_page

    query = """
    SELECT id::text AS id, time, agent_id, check_id, check_name, device_id, target, target_ip,
           target_reached, total_hops, protocol, ip_version, error
    FROM mtr_traces
    #{where_clause}
    ORDER BY #{order_clause}
    LIMIT $#{length(params) + 1}
    OFFSET $#{length(params) + 2}
    """

    count_query = """
    SELECT COUNT(*)::bigint AS total
    FROM mtr_traces
    #{where_clause}
    """

    with {:ok, %{rows: rows, columns: columns}} <- Repo.query(query, params ++ [per_page, offset]),
         {:ok, %{rows: [[total]]}} <- Repo.query(count_query, params) do
      {:ok,
       %{
         rows: Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end),
         total_count: total || 0,
         page: page,
         per_page: per_page
       }}
    end
  end

  @sobelow_skip ["SQL.Query"]
  def trace_coverage(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    srql_query = normalize_string(Keyword.get(opts, :srql_query, ""))

    {where_clause, params, _srql_sort} =
      build_trace_where_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query)

    query = """
    SELECT COUNT(*)::bigint AS trace_count,
           COUNT(*) FILTER (WHERE target_reached)::bigint AS reached_count,
           COUNT(*) FILTER (WHERE NOT target_reached)::bigint AS failed_count,
           MIN(time) AS earliest_time,
           MAX(time) AS latest_time
    FROM mtr_traces
    #{where_clause}
    """

    case Repo.query(query, params) do
      {:ok, %{rows: [[count, reached, failed, earliest, latest]]}} ->
        {:ok,
         %{
           trace_count: count || 0,
           reached_count: reached || 0,
           failed_count: failed || 0,
           earliest_time: earliest,
           latest_time: latest
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def retention_status(scope \\ nil) do
    settings =
      case MtrSettings.get_settings(scope: scope) do
        {:ok, %MtrSettings{} = settings} -> settings
        _ -> nil
      end

    MtrSettings.retention_status(settings)
  rescue
    reason ->
      %{
        configured_days: MtrSettings.default_retention_days(),
        status: :degraded,
        reason: inspect(reason),
        tables: %{}
      }
  end

  def list_pending_jobs(scope, opts \\ []) do
    pending_states = Keyword.get(opts, :states, @default_pending_states)
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    now = DateTime.utc_now()

    if is_nil(scope) do
      {:error, :missing_scope}
    else
      query =
        AgentCommand
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(
          expr(
            command_type == "mtr.run" and status in ^pending_states and
              (is_nil(expires_at) or expires_at > ^now)
          )
        )
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(500)

      with {:ok, jobs} <- read_all(query, scope) do
        jobs
        |> Enum.filter(fn job ->
          match_target?(job, target_filter) and
            match_agent?(job, agent_filter) and
            match_device?(job, device_uid, device_ip)
        end)
        |> Enum.take(25)
        |> then(&{:ok, &1})
      end
    end
  end

  def list_bulk_jobs(scope, opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    now = DateTime.utc_now()

    if is_nil(scope) do
      {:error, :missing_scope}
    else
      query =
        AgentCommand
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(expr(command_type == "mtr.bulk_run"))
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(100)

      with {:ok, jobs} <- read_all(query, scope) do
        jobs
        |> Enum.reject(&expired_active_bulk_job?(&1, now))
        |> Enum.filter(fn job ->
          match_agent?(job, agent_filter) and match_bulk_job_target?(job, target_filter)
        end)
        |> Enum.take(25)
        |> then(&{:ok, &1})
      end
    end
  end

  def build_trends(traces) when is_list(traces) do
    sorted = Enum.reverse(traces)

    hops =
      Enum.map(sorted, fn trace ->
        {trace["time"], trace["total_hops"] || 0}
      end)

    latency =
      sorted
      |> Enum.filter(fn trace ->
        (trace["destination_received"] || 0) > 0 and is_number(trace["destination_avg_us"])
      end)
      |> Enum.map(fn trace ->
        {trace["time"], trace["destination_avg_us"]}
      end)

    %{hops: hops, latency: latency}
  end

  def build_trends(_), do: %{hops: [], latency: []}

  def compare_windows(opts \\ []) do
    with {:ok, window_a} <- normalize_window(Keyword.get(opts, :window_a)),
         {:ok, window_b} <- normalize_window(Keyword.get(opts, :window_b)) do
      filters = normalize_compare_filters(opts)
      bucket_count = opts |> Keyword.get(:bucket_count, 24) |> normalize_bucket_count()
      signature_limit = opts |> Keyword.get(:signature_limit, 6) |> normalize_signature_limit()

      with {:ok, summary_a} <- window_summary(window_a, filters),
           {:ok, summary_b} <- window_summary(window_b, filters),
           {:ok, timeline_a} <- window_timeline(window_a, filters, bucket_count),
           {:ok, timeline_b} <- window_timeline(window_b, filters, bucket_count),
           {:ok, signatures_a} <- window_route_signatures(window_a, filters, signature_limit),
           {:ok, signatures_b} <- window_route_signatures(window_b, filters, signature_limit),
           {:ok, agent_rows} <- window_agent_comparison(window_a, window_b, filters) do
        {:ok,
         %{
           a: Map.merge(summary_a, %{timeline: timeline_a, route_signatures: signatures_a}),
           b: Map.merge(summary_b, %{timeline: timeline_b, route_signatures: signatures_b}),
           agents: agent_rows,
           deltas: window_deltas(summary_a, summary_b),
           filters: filters,
           elapsed_aligned?: same_duration?(window_a, window_b)
         }}
      end
    end
  end

  @sobelow_skip ["SQL.Query"]
  def get_trace_detail(scope, trace_id) when is_binary(trace_id) and trace_id != "" do
    if is_nil(scope) do
      {:error, :missing_scope}
    else
      trace_query = """
      SELECT id::text AS id, time, agent_id, gateway_id, check_id, check_name, device_id,
             target, target_ip, target_reached, total_hops, protocol,
             ip_version, packet_size, partition, error
      FROM mtr_traces
      WHERE id::text = $1
      LIMIT 1
      """

      hops_query = """
      SELECT id::text AS id, time, hop_number, addr, hostname, ecmp_addrs, asn, asn_org,
             mpls_labels, sent, received, loss_pct,
             last_us, avg_us, min_us, max_us, stddev_us,
             jitter_us, jitter_worst_us, jitter_interarrival_us
      FROM mtr_hops
      WHERE trace_id::text = $1
      ORDER BY hop_number ASC, time DESC, id DESC
      """

      with {:ok, %{rows: [trace_row], columns: trace_cols}} <- Repo.query(trace_query, [trace_id]),
           trace = trace_cols |> Enum.zip(trace_row) |> Map.new(),
           {:ok, %{rows: hop_rows, columns: hop_cols}} <- Repo.query(hops_query, [trace_id]) do
        hops = Enum.map(hop_rows, fn row -> hop_cols |> Enum.zip(row) |> Map.new() end)
        {:ok, trace, hops}
      else
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def get_trace_detail(_scope, _trace_id), do: {:error, :invalid_trace_id}

  def get_trace_detail(trace_id) when is_binary(trace_id) and trace_id != "" do
    get_trace_detail(%{}, trace_id)
  end

  def get_trace_detail(_), do: {:error, :invalid_trace_id}

  def suppress_completed_pending_jobs(pending_jobs, traces) when is_list(pending_jobs) and is_list(traces) do
    completed_command_ids =
      traces
      |> Enum.map(&Map.get(&1, "check_id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&to_string/1)

    Enum.reject(pending_jobs, fn job ->
      job_id = Map.get(job, :id) || Map.get(job, "id")
      is_binary(job_id) and MapSet.member?(completed_command_ids, job_id)
    end)
  end

  def suppress_completed_pending_jobs(pending_jobs, _traces), do: pending_jobs

  defp match_bulk_job_target?(_job, ""), do: true

  defp match_bulk_job_target?(job, target_filter) do
    targets =
      job
      |> Map.get(:payload, %{})
      |> Map.get("targets", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    Enum.any?(targets, &String.contains?(String.downcase(&1), String.downcase(target_filter)))
  end

  defp build_trace_where(target_filter, agent_filter, device_uid, device_ip) do
    {conditions, params} =
      build_trace_conditions(target_filter, agent_filter, device_uid, device_ip)

    where_clause =
      if conditions == [] do
        ""
      else
        "WHERE " <> Enum.join(conditions, " AND ")
      end

    {where_clause, params}
  end

  defp normalize_window(%{start: start_time, end: end_time} = window) do
    with {:ok, start_dt} <- normalize_compare_datetime(start_time),
         {:ok, end_dt} <- normalize_compare_datetime(end_time),
         :lt <- DateTime.compare(start_dt, end_dt) do
      {:ok,
       %{
         start: start_dt,
         end: end_dt,
         label: Map.get(window, :label) || Map.get(window, "label") || "Window"
       }}
    else
      :eq -> {:error, :empty_window}
      :gt -> {:error, :invalid_window}
      error -> error
    end
  end

  defp normalize_window(%{"start" => start_time, "end" => end_time} = window) do
    normalize_window(%{start: start_time, end: end_time, label: Map.get(window, "label")})
  end

  defp normalize_window(_window), do: {:error, :invalid_window}

  defp normalize_compare_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_compare_datetime(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> then(&{:ok, &1})
  end

  defp normalize_compare_datetime(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, :invalid_datetime}

      String.ends_with?(value, "Z") or String.contains?(value, "+") ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> normalize_compare_datetime(dt)
          {:error, _} -> parse_naive_compare_datetime(value)
        end

      true ->
        parse_naive_compare_datetime(value)
    end
  end

  defp normalize_compare_datetime(_value), do: {:error, :invalid_datetime}

  defp parse_naive_compare_datetime(value) do
    value
    |> String.replace(" ", "T")
    |> then(fn normalized ->
      case NaiveDateTime.from_iso8601(normalized) do
        {:ok, ndt} -> normalize_compare_datetime(ndt)
        {:error, _} -> {:error, :invalid_datetime}
      end
    end)
  end

  defp normalize_compare_filters(opts) do
    %{
      target_filter: normalize_string(Keyword.get(opts, :target_filter, "")),
      agent_filter: normalize_string(Keyword.get(opts, :agent_filter, "")),
      protocol: normalize_protocol_filter(Keyword.get(opts, :protocol, "")),
      reached: normalize_reached_filter(Keyword.get(opts, :reached, ""))
    }
  end

  defp normalize_protocol_filter(nil), do: ""
  defp normalize_protocol_filter(""), do: ""

  defp normalize_protocol_filter(value) do
    value
    |> to_string_safe()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_reached_filter(value) when value in [true, "true", "reached", "yes", "1"], do: true
  defp normalize_reached_filter(value) when value in [false, "false", "unreachable", "no", "0"], do: false
  defp normalize_reached_filter(_value), do: :any

  defp normalize_bucket_count(value) when is_integer(value), do: value |> max(6) |> min(96)

  defp normalize_bucket_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_bucket_count(parsed)
      _ -> 24
    end
  end

  defp normalize_bucket_count(_value), do: 24

  defp normalize_signature_limit(value) when is_integer(value), do: value |> max(1) |> min(20)
  defp normalize_signature_limit(_value), do: 6

  @sobelow_skip ["SQL.Query"]
  defp window_summary(window, filters) do
    {filter_clause, params} = build_compare_where(filters, 3, "t")

    query = """
    WITH selected_traces AS (
      SELECT id, time, agent_id, target, target_ip, target_reached, total_hops, protocol
      FROM mtr_traces t
      WHERE t.time >= $1 AND t.time < $2
      #{filter_clause}
    ),
    terminal_hops AS (
      SELECT trace_id, sent, received, avg_us
      FROM (
        SELECT
          h.trace_id,
          h.sent,
          h.received,
          h.avg_us,
          ROW_NUMBER() OVER (
            PARTITION BY h.trace_id
            ORDER BY h.time DESC, h.id DESC
          ) AS terminal_rank
        FROM mtr_hops h
        INNER JOIN selected_traces st
          ON st.id = h.trace_id
          AND st.target_reached
          AND h.hop_number = st.total_hops
      ) terminal_candidates
      WHERE terminal_rank = 1
    )
    SELECT
      COUNT(st.id)::bigint AS trace_count,
      COUNT(st.id) FILTER (WHERE st.target_reached)::bigint AS reached_count,
      COUNT(st.id) FILTER (WHERE NOT st.target_reached)::bigint AS failed_count,
      COALESCE(AVG(NULLIF(st.total_hops, 0)), 0)::float AS avg_hops,
      CASE
        WHEN COALESCE(SUM(th.received) FILTER (WHERE th.received > 0 AND th.avg_us IS NOT NULL), 0) > 0
        THEN (
          SUM(th.avg_us::numeric * th.received::numeric) FILTER (WHERE th.received > 0 AND th.avg_us IS NOT NULL) /
          SUM(th.received) FILTER (WHERE th.received > 0 AND th.avg_us IS NOT NULL)
        )::float
      END AS avg_destination_us,
      CASE
        WHEN COALESCE(SUM(th.sent) FILTER (WHERE th.sent > 0), 0) > 0
        THEN (
          100.0 * (
            SUM(th.sent) FILTER (WHERE th.sent > 0) -
            SUM(COALESCE(th.received, 0)) FILTER (WHERE th.sent > 0)
          ) / SUM(th.sent) FILTER (WHERE th.sent > 0)
        )::float
      END AS destination_loss_pct,
      COUNT(th.trace_id)::bigint AS endpoint_sample_count,
      COUNT(DISTINCT st.agent_id)::bigint AS agent_count,
      COUNT(DISTINCT COALESCE(NULLIF(st.target_ip, ''), st.target))::bigint AS target_count
    FROM selected_traces st
    LEFT JOIN terminal_hops th ON th.trace_id = st.id
    """

    case Repo.query(query, [window.start, window.end] ++ params) do
      {:ok,
       %{
         rows: [
           [
             trace_count,
             reached_count,
             failed_count,
             avg_hops,
             avg_destination_us,
             destination_loss_pct,
             endpoint_sample_count,
             agent_count,
             target_count
           ]
         ]
       }} ->
        {:ok,
         %{
           label: window.label,
           start: window.start,
           end: window.end,
           duration_seconds: DateTime.diff(window.end, window.start, :second),
           trace_count: trace_count || 0,
           reached_count: reached_count || 0,
           failed_count: failed_count || 0,
           success_rate: percent_float(reached_count || 0, trace_count || 0),
           avg_hops: round_float(avg_hops),
           avg_destination_us: round_nullable_float(avg_destination_us),
           destination_loss_pct: round_nullable_float(destination_loss_pct),
           endpoint_sample_count: endpoint_sample_count || 0,
           agent_count: agent_count || 0,
           target_count: target_count || 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp window_timeline(window, filters, bucket_count) do
    {filter_clause, params} = build_compare_where(filters, 4, "t")

    query = """
    WITH bounds AS (
      SELECT
        $1::timestamptz AS start_time,
        $2::timestamptz AS end_time,
        GREATEST(($2::timestamptz - $1::timestamptz) / $3::double precision, interval '1 second') AS step
    ),
    buckets AS (
      SELECT
        start_time + (idx * step) AS bucket_start,
        step
      FROM bounds
      CROSS JOIN generate_series(0, $3::integer - 1) AS idx
    )
    SELECT
      b.bucket_start,
      b.bucket_start + b.step AS bucket_end,
      COUNT(t.id)::bigint AS trace_count,
      COUNT(t.id) FILTER (WHERE t.target_reached)::bigint AS reached_count,
      COUNT(t.id) FILTER (WHERE NOT t.target_reached)::bigint AS failed_count
    FROM buckets b
    LEFT JOIN mtr_traces t
      ON t.time >= b.bucket_start
     AND t.time < b.bucket_start + b.step
     #{filter_clause}
    GROUP BY b.bucket_start, b.step
    ORDER BY b.bucket_start ASC
    """

    case Repo.query(query, [window.start, window.end, bucket_count] ++ params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp window_route_signatures(window, filters, limit) do
    {filter_clause, params} = build_compare_where(filters, 4, "t")

    query = """
    WITH selected_traces AS (
      SELECT id, time, agent_id, target, target_ip, target_reached, total_hops, protocol
      FROM mtr_traces t
      WHERE t.time >= $1 AND t.time < $2
      #{filter_clause}
    ),
    paths AS (
      SELECT
        st.id::text AS trace_id,
        st.time,
        st.agent_id,
        st.target,
        st.target_ip,
        st.target_reached,
        array_agg(COALESCE(NULLIF(h.addr, ''), '*') ORDER BY h.hop_number) AS hop_addrs
      FROM selected_traces st
      LEFT JOIN mtr_hops h ON h.trace_id = st.id
      GROUP BY st.id, st.time, st.agent_id, st.target, st.target_ip, st.target_reached
    ),
    signed_paths AS (
      SELECT
        trace_id,
        time,
        agent_id,
        target,
        target_ip,
        target_reached,
        CASE
          WHEN hop_addrs IS NULL THEN '*'
          ELSE array_to_string(hop_addrs, '>')
        END AS path_signature,
        CASE
          WHEN hop_addrs IS NULL THEN '*'
          ELSE array_to_string(hop_addrs, ' -> ')
        END AS path_preview
      FROM paths
    )
    SELECT
      md5(path_signature) AS signature_id,
      path_preview,
      COUNT(*)::bigint AS trace_count,
      COUNT(*) FILTER (WHERE target_reached)::bigint AS reached_count,
      COUNT(DISTINCT agent_id)::bigint AS agent_count,
      (array_agg(trace_id ORDER BY time DESC))[1] AS representative_trace_id,
      MAX(time) AS latest_time,
      array_agg(DISTINCT agent_id ORDER BY agent_id) AS agent_ids
    FROM signed_paths
    GROUP BY path_signature, path_preview
    ORDER BY COUNT(*) DESC, MAX(time) DESC
    LIMIT $3
    """

    case Repo.query(query, [window.start, window.end, limit] ++ params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp window_agent_comparison(window_a, window_b, filters) do
    {filter_clause, params} = build_compare_where(filters, 5, "t")

    query = """
    WITH selected_traces AS (
      SELECT
        CASE
          WHEN t.time >= $1 AND t.time < $2 THEN 'a'
          WHEN t.time >= $3 AND t.time < $4 THEN 'b'
        END AS side,
        t.agent_id,
        t.target_reached
      FROM mtr_traces t
      WHERE ((t.time >= $1 AND t.time < $2) OR (t.time >= $3 AND t.time < $4))
      #{filter_clause}
    )
    SELECT
      agent_id,
      COUNT(*) FILTER (WHERE side = 'a')::bigint AS a_trace_count,
      COUNT(*) FILTER (WHERE side = 'a' AND target_reached)::bigint AS a_reached_count,
      COUNT(*) FILTER (WHERE side = 'b')::bigint AS b_trace_count,
      COUNT(*) FILTER (WHERE side = 'b' AND target_reached)::bigint AS b_reached_count
    FROM selected_traces
    WHERE side IS NOT NULL
    GROUP BY agent_id
    ORDER BY agent_id ASC
    LIMIT 50
    """

    case Repo.query(query, [window_a.start, window_a.end, window_b.start, window_b.end] ++ params) do
      {:ok, %{rows: rows, columns: columns}} ->
        rows =
          Enum.map(rows, fn row ->
            row
            |> then(&(columns |> Enum.zip(&1) |> Map.new()))
            |> Map.update!("a_reached_count", &(&1 || 0))
            |> Map.update!("a_trace_count", &(&1 || 0))
            |> Map.update!("b_reached_count", &(&1 || 0))
            |> Map.update!("b_trace_count", &(&1 || 0))
            |> then(fn agent ->
              agent
              |> Map.put("a_success_rate", percent_float(agent["a_reached_count"], agent["a_trace_count"]))
              |> Map.put("b_success_rate", percent_float(agent["b_reached_count"], agent["b_trace_count"]))
            end)
          end)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_compare_where(filters, start_idx, table_alias) do
    conditions = []
    params = []
    idx = start_idx
    prefix = "#{table_alias}."

    {conditions, params, idx} =
      case Map.get(filters, :target_filter, "") do
        "" ->
          {conditions, params, idx}

        target_filter ->
          condition = "(#{prefix}target ILIKE $#{idx} OR #{prefix}target_ip ILIKE $#{idx})"
          {conditions ++ [condition], params ++ ["%#{target_filter}%"], idx + 1}
      end

    {conditions, params, idx} =
      case Map.get(filters, :agent_filter, "") do
        "" ->
          {conditions, params, idx}

        agent_filter ->
          {conditions ++ ["#{prefix}agent_id ILIKE $#{idx}"], params ++ ["%#{agent_filter}%"], idx + 1}
      end

    {conditions, params, idx} =
      case Map.get(filters, :protocol, "") do
        "" ->
          {conditions, params, idx}

        protocol ->
          {conditions ++ ["#{prefix}protocol = $#{idx}"], params ++ [protocol], idx + 1}
      end

    {conditions, params, _idx} =
      case Map.get(filters, :reached, :any) do
        :any ->
          {conditions, params, idx}

        reached? when is_boolean(reached?) ->
          {conditions ++ ["#{prefix}target_reached = $#{idx}"], params ++ [reached?], idx + 1}
      end

    clause =
      case conditions do
        [] -> ""
        _ -> "AND " <> Enum.join(conditions, " AND ")
      end

    {clause, params}
  end

  defp window_deltas(a, b) do
    %{
      trace_count: (a.trace_count || 0) - (b.trace_count || 0),
      success_rate: round_float((a.success_rate || 0.0) - (b.success_rate || 0.0)),
      avg_hops: round_float((a.avg_hops || 0.0) - (b.avg_hops || 0.0)),
      avg_destination_us: nullable_delta(a.avg_destination_us, b.avg_destination_us),
      destination_loss_pct: nullable_delta(a.destination_loss_pct, b.destination_loss_pct)
    }
  end

  defp same_duration?(window_a, window_b) do
    DateTime.diff(window_a.end, window_a.start, :second) ==
      DateTime.diff(window_b.end, window_b.start, :second)
  end

  defp percent_float(_value, total) when total in [0, 0.0, nil], do: 0.0

  defp percent_float(value, total) do
    value
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round(1)
  end

  defp round_float(nil), do: 0.0
  defp round_float(value) when is_integer(value), do: value * 1.0
  defp round_float(value) when is_float(value), do: Float.round(value, 1)
  defp round_float(_value), do: 0.0

  defp round_nullable_float(value) when is_integer(value), do: value * 1.0
  defp round_nullable_float(value) when is_float(value), do: Float.round(value, 1)
  defp round_nullable_float(_value), do: nil

  defp nullable_delta(a, b) when is_number(a) and is_number(b), do: round_nullable_float(a - b)
  defp nullable_delta(_a, _b), do: nil

  defp build_trace_conditions(target_filter, agent_filter, device_uid, device_ip) do
    conditions = []
    params = []
    idx = 1

    {conditions, params, idx} =
      if target_filter == "" do
        {conditions, params, idx}
      else
        {conditions ++ ["(target ILIKE $#{idx} OR target_ip ILIKE $#{idx})"], params ++ ["%#{target_filter}%"], idx + 1}
      end

    {conditions, params, idx} =
      if agent_filter == "" do
        {conditions, params, idx}
      else
        {conditions ++ ["agent_id ILIKE $#{idx}"], params ++ ["%#{agent_filter}%"], idx + 1}
      end

    {conditions, params, _idx} =
      case {device_uid, device_ip} do
        {uid, ip} when is_binary(uid) and uid != "" and is_binary(ip) and ip != "" ->
          {conditions ++ ["(device_id::text = $#{idx} OR target_ip = $#{idx + 1})"], params ++ [uid, ip], idx + 2}

        {uid, _ip} when is_binary(uid) and uid != "" ->
          {conditions ++ ["device_id::text = $#{idx}"], params ++ [uid], idx + 1}

        {_uid, ip} when is_binary(ip) and ip != "" ->
          {conditions ++ ["target_ip = $#{idx}"], params ++ [ip], idx + 1}

        _ ->
          {conditions, params, idx}
      end

    {conditions, params}
  end

  defp read_all(query, scope) do
    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: jobs}} -> {:ok, jobs}
      {:ok, jobs} when is_list(jobs) -> {:ok, jobs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_target?(_job, ""), do: true

  defp match_target?(job, target_filter) do
    target =
      job
      |> Map.get(:payload, %{})
      |> fetch_map("target")
      |> to_string_safe()
      |> String.downcase()

    String.contains?(target, String.downcase(target_filter))
  end

  defp match_agent?(_job, ""), do: true

  defp match_agent?(job, agent_filter) do
    job
    |> Map.get(:agent_id, "")
    |> to_string_safe()
    |> String.downcase()
    |> String.contains?(String.downcase(agent_filter))
  end

  defp match_device?(_job, nil, nil), do: true

  defp match_device?(job, device_uid, device_ip) do
    device_uid =
      if is_binary(device_uid) and String.trim(device_uid) == "", do: nil, else: device_uid

    device_ip = if is_binary(device_ip) and String.trim(device_ip) == "", do: nil, else: device_ip

    context = Map.get(job, :context, %{})
    payload = Map.get(job, :payload, %{})

    context_device_uid =
      context
      |> fetch_map("device_uid")
      |> to_string_safe()
      |> String.trim()

    context_target_ip =
      context
      |> fetch_map("target_ip")
      |> to_string_safe()
      |> String.trim()

    payload_target =
      payload
      |> fetch_map("target")
      |> to_string_safe()
      |> String.trim()

    uid_match? = is_binary(device_uid) and context_device_uid == String.trim(device_uid)

    ip_match? =
      is_binary(device_ip) and
        (payload_target == String.trim(device_ip) or context_target_ip == String.trim(device_ip))

    uid_match? || ip_match?
  end

  defp fetch_map(map, key) when is_map(map) and is_binary(key) do
    case key do
      "target" -> Map.get(map, "target") || Map.get(map, :target)
      "target_ip" -> Map.get(map, "target_ip") || Map.get(map, :target_ip)
      "device_uid" -> Map.get(map, "device_uid") || Map.get(map, :device_uid)
      _ -> Map.get(map, key)
    end
  end

  defp fetch_map(_map, _key), do: nil

  defp expired_active_bulk_job?(job, now) when is_map(job) do
    Map.get(job, :status) in @default_pending_states and
      case Map.get(job, :expires_at) do
        %DateTime{} = expires_at -> DateTime.compare(expires_at, now) != :gt
        _ -> false
      end
  end

  defp expired_active_bulk_job?(_job, _now), do: false

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "", else: value
  end

  defp normalize_string(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: ""

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_page(_), do: 1

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> 50
    end
  end

  defp normalize_limit(_), do: 50

  defp default_history_page_size do
    MtrSettingsRuntime.settings()
    |> Map.get(:mtr_history_page_size_default, 50)
    |> normalize_limit()
  rescue
    _ -> 50
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)

  defp build_trace_where_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query) do
    {conditions, params} =
      build_trace_conditions(target_filter, agent_filter, device_uid, device_ip)

    idx = length(params) + 1

    {srql_conditions, srql_params, _idx, srql_sort} = parse_srql_conditions(srql_query, idx)
    all_conditions = conditions ++ srql_conditions
    all_params = params ++ srql_params

    final_where =
      if all_conditions == [] do
        ""
      else
        "WHERE " <> Enum.join(all_conditions, " AND ")
      end

    {final_where, all_params, srql_sort}
  end

  defp parse_srql_conditions(query, start_idx) when is_binary(query) do
    query
    |> tokenize_srql()
    |> Enum.reduce({[], [], start_idx, nil}, fn token, {conditions, params, idx, sort} ->
      token
      |> String.trim()
      |> maybe_parse_token(conditions, params, idx, sort)
    end)
  end

  defp parse_srql_conditions(_, start_idx), do: {[], [], start_idx, nil}

  defp maybe_parse_token("", conditions, params, idx, sort), do: {conditions, params, idx, sort}

  defp maybe_parse_token(token, conditions, params, idx, sort) do
    cond do
      String.starts_with?(token, "in:") ->
        {conditions, params, idx, sort}

      String.starts_with?(token, "limit:") ->
        {conditions, params, idx, sort}

      String.starts_with?(token, "sort:") ->
        {conditions, params, idx, parse_sort_token(token) || sort}

      String.starts_with?(token, "time:") ->
        apply_time_filter(token, conditions, params, idx, sort)

      String.contains?(token, ":") ->
        apply_field_filter(token, conditions, params, idx, sort)

      true ->
        text = normalize_srql_value(token)

        if text == "" do
          {conditions, params, idx, sort}
        else
          condition =
            "(target ILIKE $#{idx} OR target_ip ILIKE $#{idx} OR agent_id ILIKE $#{idx} OR check_name ILIKE $#{idx})"

          {conditions ++ [condition], params ++ ["%#{text}%"], idx + 1, sort}
        end
    end
  end

  defp apply_field_filter(token, conditions, params, idx, sort) do
    case String.split(token, ":", parts: 2) do
      [raw_field, raw_value] ->
        field = String.downcase(raw_field)
        value = normalize_srql_value(raw_value)
        apply_filter_by_field(field, value, conditions, params, idx, sort)

      _ ->
        {conditions, params, idx, sort}
    end
  end

  defp apply_filter_by_field("", _value, conditions, params, idx, sort), do: {conditions, params, idx, sort}

  defp apply_filter_by_field(_field, value, conditions, params, idx, sort) when not is_binary(value) or value == "" do
    {conditions, params, idx, sort}
  end

  defp apply_filter_by_field(field, value, conditions, params, idx, sort) do
    col = Map.get(@safe_filter_columns, field)

    cond do
      is_nil(col) or not MapSet.member?(@allowed_filter_fields, field) ->
        {conditions, params, idx, sort}

      MapSet.member?(@boolean_filter_fields, field) ->
        maybe_add_boolean_filter(parse_boolean(value), col, conditions, params, idx, sort)

      MapSet.member?(@exact_filter_fields, field) ->
        {conditions ++ ["#{col} = $#{idx}"], params ++ [value], idx + 1, sort}

      true ->
        {conditions ++ ["#{col} ILIKE $#{idx}"], params ++ ["%#{value}%"], idx + 1, sort}
    end
  end

  defp maybe_add_boolean_filter(nil, _field, conditions, params, idx, sort), do: {conditions, params, idx, sort}

  defp maybe_add_boolean_filter(bool_value, field, conditions, params, idx, sort) do
    {conditions ++ ["#{field} = $#{idx}"], params ++ [bool_value], idx + 1, sort}
  end

  defp parse_sort_token("sort:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [field, dir] -> parse_sort_mapping(field, dir)
      _ -> nil
    end
  end

  defp parse_sort_token(_token), do: nil

  defp parse_sort_mapping(field, dir) do
    case Map.fetch(@allowed_sort_fields, field) do
      {:ok, mapped_field} ->
        mapped_dir = if String.downcase(dir) == "asc", do: "ASC", else: "DESC"
        {mapped_field, mapped_dir}

      :error ->
        nil
    end
  end

  defp order_clause(sort_field, sort_dir) do
    safe_field = Map.get(@allowed_sort_fields, sort_field, "time")
    safe_dir = if String.upcase(to_string(sort_dir)) == "ASC", do: "ASC", else: "DESC"
    tie_dir = if safe_dir == "ASC", do: "ASC", else: "DESC"

    if safe_field == "time" do
      "#{safe_field} #{safe_dir}, id #{tie_dir}"
    else
      "#{safe_field} #{safe_dir}, time #{tie_dir}, id #{tie_dir}"
    end
  end

  defp apply_time_filter("time:" <> raw_value, conditions, params, idx, sort) do
    raw_value
    |> normalize_srql_value()
    |> parse_time_range()
    |> case do
      {:ok, nil, nil} ->
        {conditions, params, idx, sort}

      {:ok, start_dt, nil} ->
        {conditions ++ ["time >= $#{idx}"], params ++ [start_dt], idx + 1, sort}

      {:ok, nil, end_dt} ->
        {conditions ++ ["time < $#{idx}"], params ++ [end_dt], idx + 1, sort}

      {:ok, start_dt, end_dt} ->
        {conditions ++ ["time >= $#{idx} AND time < $#{idx + 1}"], params ++ [start_dt, end_dt], idx + 2, sort}

      :error ->
        {conditions, params, idx, sort}
    end
  end

  defp apply_time_filter(_token, conditions, params, idx, sort), do: {conditions, params, idx, sort}

  defp parse_time_range(""), do: {:ok, nil, nil}

  defp parse_time_range("last_" <> rest) do
    with {:ok, seconds} <- relative_seconds(rest) do
      {:ok, DateTime.add(DateTime.utc_now(), -seconds, :second), nil}
    end
  end

  defp parse_time_range("[" <> rest) do
    value = String.trim_trailing(rest, "]")

    case String.split(value, ",", parts: 2) do
      [start_raw, end_raw] ->
        with {:ok, start_dt} <- parse_optional_datetime(start_raw),
             {:ok, end_dt} <- parse_optional_datetime(end_raw) do
          {:ok, start_dt, end_dt}
        end

      _ ->
        :error
    end
  end

  defp parse_time_range(_), do: :error

  defp relative_seconds(rest) do
    case Regex.run(~r/^(\d+)([mhdw])$/, rest) do
      [_, amount, unit] ->
        {amount, ""} = Integer.parse(amount)

        multiplier =
          case unit do
            "m" -> 60
            "h" -> 60 * 60
            "d" -> 24 * 60 * 60
            "w" -> 7 * 24 * 60 * 60
          end

        {:ok, amount * multiplier}

      _ ->
        :error
    end
  end

  defp parse_optional_datetime(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:ok, nil}
    else
      parse_datetime(value)
    end
  end

  defp parse_datetime(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, dt, _offset} = DateTime.from_iso8601(value)
        {:ok, dt}

      match?({:ok, _}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(value)
        {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      true ->
        :error
    end
  end

  defp tokenize_srql(query) do
    ~r/"[^"]*"|\S+/
    |> Regex.scan(query)
    |> Enum.map(&List.first/1)
  end

  defp normalize_srql_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim("\"")
  end

  defp parse_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> nil
    end
  end
end
