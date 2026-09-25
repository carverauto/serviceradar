defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrData do
  @moduledoc """
  MTR trace readers for the diagnostics pages, the device MTR tab and the
  Compare page.

  Exactly one telemetry backend is active. With `analytics.starrocks.enabled`
  on, every trace/hop read here is answered by `MtrWarehouse` and the CNPG
  `mtr_traces`/`mtr_hops` hypertables are never queried: they stop receiving
  rows once the warehouse is enabled. With it off, the CNPG SQL below runs
  exactly as it always has. Both backends' answers are shaped by the same code,
  so callers and templates see one result shape.

  Filters (the page's target/agent/device inputs, the SRQL-style query string
  and the Compare filters) are parsed once into dialect-free terms; the CNPG
  renderer here produces the where-clauses CNPG has always run, and
  `MtrWarehouse` renders the same terms for the warehouse.

  `:cnpg_query` in `opts` replaces `Repo.query/2` and `:starrocks_query` the
  warehouse client; both exist for tests.
  """

  import Ash.Expr

  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Observability.MtrSettings
  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadar.Repo
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepth
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse

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

  def list_traces(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    limit = normalize_limit(Keyword.get(opts, :limit, 50))

    terms = trace_filter_terms(target_filter, agent_filter, device_uid, device_ip)

    if MtrWarehouse.enabled?() do
      terms |> MtrWarehouse.list_traces(limit, opts) |> rows_to_maps()
    else
      cnpg_list_traces(terms, limit, opts)
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp cnpg_list_traces(terms, limit, opts) do
    {where_clause, params} = build_trace_where(terms)

    query = """
    WITH selected_traces AS (
      SELECT id, time, agent_id, check_id, check_name, device_id, target, target_ip,
             target_reached, total_hops, probed_hops, last_responding_hop, protocol, tcp_port,
             ip_version, error
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
          AND h.time >= st.time
        WHERE h.time >= (SELECT MIN(time) FROM selected_traces)
      ) ranked_terminal_hops
      WHERE terminal_rank = 1
    )
    SELECT st.id::text AS id, st.time, st.agent_id, st.check_id, st.check_name, st.device_id,
           st.target, st.target_ip, st.target_reached, st.total_hops, st.probed_hops,
           st.last_responding_hop, st.protocol, st.tcp_port, st.ip_version,
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

    query_fun = cnpg_query(opts)
    rows_to_maps(query_fun.(query, params ++ [limit]))
  end

  def list_traces_paginated(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    srql_query = normalize_string(Keyword.get(opts, :srql_query, ""))
    page = normalize_page(Keyword.get(opts, :page, 1))
    per_page = normalize_limit(Keyword.get(opts, :limit, default_history_page_size()))

    {terms, srql_sort} =
      trace_terms_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query)

    sort = srql_sort || @default_sort
    offset = (page - 1) * per_page

    result =
      if MtrWarehouse.enabled?() do
        MtrWarehouse.trace_page(terms, sort, per_page, offset, opts)
      else
        cnpg_trace_page(terms, sort, per_page, offset, opts)
      end

    with {:ok, rows, total} <- result do
      {:ok, %{rows: rows, total_count: total || 0, page: page, per_page: per_page}}
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp cnpg_trace_page(terms, {sort_field, sort_dir}, per_page, offset, opts) do
    {where_clause, params} = build_trace_where(terms)
    order_clause = order_clause(sort_field, sort_dir)

    query = """
    SELECT id::text AS id, time, agent_id, check_id, check_name, device_id, target, target_ip,
           target_reached, total_hops, probed_hops, last_responding_hop, protocol, tcp_port,
           ip_version, error
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

    with {:ok, %{rows: rows, columns: columns}} <- cnpg_query(opts).(query, params ++ [per_page, offset]),
         {:ok, %{rows: [[total]]}} <- cnpg_query(opts).(count_query, params) do
      {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end), total}
    end
  end

  def trace_coverage(opts \\ []) do
    target_filter = normalize_string(Keyword.get(opts, :target_filter, ""))
    agent_filter = normalize_string(Keyword.get(opts, :agent_filter, ""))
    device_uid = normalize_string(Keyword.get(opts, :device_uid))
    device_ip = normalize_string(Keyword.get(opts, :device_ip))
    srql_query = normalize_string(Keyword.get(opts, :srql_query, ""))

    {terms, _srql_sort} =
      trace_terms_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query)

    result =
      if MtrWarehouse.enabled?() do
        MtrWarehouse.trace_coverage(terms, opts)
      else
        cnpg_trace_coverage(terms, opts)
      end

    case result do
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

  @sobelow_skip ["SQL.Query"]
  defp cnpg_trace_coverage(terms, opts) do
    {where_clause, params} = build_trace_where(terms)

    query = """
    SELECT COUNT(*)::bigint AS trace_count,
           COUNT(*) FILTER (WHERE target_reached)::bigint AS reached_count,
           COUNT(*) FILTER (WHERE NOT target_reached)::bigint AS failed_count,
           MIN(time) AS earliest_time,
           MAX(time) AS latest_time
    FROM mtr_traces
    #{where_clause}
    """

    cnpg_query(opts).(query, params)
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
        {trace["time"], MtrDepth.bar_depth(trace)}
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

      with {:ok, summary_a} <- window_summary(window_a, filters, opts),
           {:ok, summary_b} <- window_summary(window_b, filters, opts),
           {:ok, timeline_a} <- window_timeline(window_a, filters, bucket_count, opts),
           {:ok, timeline_b} <- window_timeline(window_b, filters, bucket_count, opts),
           {:ok, signatures_a} <- window_route_signatures(window_a, filters, signature_limit, opts),
           {:ok, signatures_b} <- window_route_signatures(window_b, filters, signature_limit, opts),
           {:ok, agent_rows} <- window_agent_comparison(window_a, window_b, filters, opts) do
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

  @doc """
  Loads one trace and its hops. Pass `time:` when the caller already knows
  the trace's time (from a listed row): it bounds the trace lookup to one
  chunk, which an id alone cannot do once chunks are compressed. With the
  warehouse enabled it reads `MtrWarehouse.trace_detail/3`, which also takes
  `hop_limit:`.
  """
  def get_trace_detail(scope, trace_id, opts \\ [])

  def get_trace_detail(scope, trace_id, opts) when is_binary(trace_id) and trace_id != "" do
    cond do
      is_nil(scope) -> {:error, :missing_scope}
      Ecto.UUID.cast(trace_id) == :error -> {:error, :not_found}
      MtrWarehouse.enabled?() -> MtrWarehouse.trace_detail(trace_id, Keyword.get(opts, :time), opts)
      true -> query_trace_detail(Ecto.UUID.dump!(trace_id), Keyword.get(opts, :time), opts)
    end
  end

  def get_trace_detail(_scope, _trace_id, _opts), do: {:error, :invalid_trace_id}

  # Both lookups compare the uuid column itself; casting the column to text
  # would defeat its index. A hop is never older than its trace, so the trace's
  # time bounds the hop lookup and lets Timescale skip older chunks, compressed
  # ones included.
  @sobelow_skip ["SQL.Query"]
  defp query_trace_detail(trace_uuid, time, opts) do
    {time_clause, trace_params} =
      case time do
        %DateTime{} -> {"AND time = $2", [trace_uuid, time]}
        _ -> {"", [trace_uuid]}
      end

    trace_query = """
    SELECT id::text AS id, time, agent_id, gateway_id, check_id, check_name, device_id,
           target, target_ip, target_reached, total_hops, probed_hops, last_responding_hop,
           protocol, tcp_port, ip_version, packet_size, partition, error,
           tcp_handshake_ttl, tcp_handshake_attempts, tcp_syn_sent, tcp_synack_received,
           tcp_rst_received, tcp_syn_unanswered, tcp_syn_drop_pct, tcp_syn_retransmits,
           tcp_answered_after_retx, tcp_ack_mismatch, tcp_synack_duplicates,
           tcp_handshake_rtt_min_us, tcp_handshake_rtt_avg_us, tcp_handshake_rtt_max_us,
           tcp_server_response_us
    FROM mtr_traces
    WHERE id = $1 #{time_clause}
    LIMIT 1
    """

    hops_query = """
    SELECT id::text AS id, time, hop_number, addr, hostname, ecmp_addrs, asn, asn_org,
           mpls_labels, sent, received, loss_pct,
           last_us, avg_us, min_us, max_us, stddev_us,
           jitter_us, jitter_worst_us, jitter_interarrival_us, unreachable_code,
           reply_time_exceeded, reply_unreachable, reply_synack, reply_rst
    FROM mtr_hops
    WHERE trace_id = $1 AND time >= $2
    ORDER BY hop_number ASC, time DESC, id DESC
    """

    with {:ok, %{rows: [trace_row], columns: trace_cols}} <- cnpg_query(opts).(trace_query, trace_params),
         trace = trace_cols |> Enum.zip(trace_row) |> Map.new(),
         {:ok, %{rows: hop_rows, columns: hop_cols}} <-
           cnpg_query(opts).(hops_query, [trace_uuid, trace["time"]]) do
      hops = Enum.map(hop_rows, fn row -> hop_cols |> Enum.zip(row) |> Map.new() end)
      {:ok, trace, hops}
    else
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_trace_detail(trace_id) when is_binary(trace_id) and trace_id != "" do
    get_trace_detail(%{}, trace_id, [])
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

  defp build_trace_where(terms) do
    {conditions, params} = cnpg_conditions(terms, 1, "")

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

  defp window_summary(window, filters, opts) do
    result =
      if MtrWarehouse.enabled?() do
        MtrWarehouse.window_summary(window, compare_terms(filters), opts)
      else
        cnpg_window_summary(window, filters, opts)
      end

    case result do
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
  defp cnpg_window_summary(window, filters, opts) do
    {filter_clause, params} = build_compare_where(filters, 3, "t")

    query = """
    WITH selected_traces AS (
      SELECT id, time, agent_id, target, target_ip, target_reached, total_hops,
             last_responding_hop, protocol
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
          AND h.time >= st.time
        WHERE h.time >= $1 AND h.time < $2
      ) terminal_candidates
      WHERE terminal_rank = 1
    )
    SELECT
      COUNT(st.id)::bigint AS trace_count,
      COUNT(st.id) FILTER (WHERE st.target_reached)::bigint AS reached_count,
      COUNT(st.id) FILTER (WHERE NOT st.target_reached)::bigint AS failed_count,
      COALESCE(AVG(NULLIF(
        CASE
          WHEN st.target_reached THEN st.total_hops
          ELSE COALESCE(
            st.last_responding_hop,
            (
              SELECT COALESCE(MAX(h.hop_number) FILTER (WHERE h.received > 0), 0)
              FROM mtr_hops h
              WHERE h.trace_id = st.id AND h.time >= st.time
              HAVING COUNT(*) > 0
            ),
            st.total_hops
          )
        END,
        0
      )), 0)::float AS avg_hops,
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

    cnpg_query(opts).(query, [window.start, window.end] ++ params)
  end

  defp window_timeline(window, filters, bucket_count, opts) do
    if MtrWarehouse.enabled?() do
      window |> MtrWarehouse.window_timeline(compare_terms(filters), bucket_count, opts) |> rows_to_maps()
    else
      cnpg_window_timeline(window, filters, bucket_count, opts)
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp cnpg_window_timeline(window, filters, bucket_count, opts) do
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

    query_fun = cnpg_query(opts)
    rows_to_maps(query_fun.(query, [window.start, window.end, bucket_count] ++ params))
  end

  defp window_route_signatures(window, filters, limit, opts) do
    if MtrWarehouse.enabled?() do
      window |> MtrWarehouse.window_route_signatures(compare_terms(filters), limit, opts) |> rows_to_maps()
    else
      cnpg_window_route_signatures(window, filters, limit, opts)
    end
  end

  @sobelow_skip ["SQL.Query"]
  defp cnpg_window_route_signatures(window, filters, limit, opts) do
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
      LEFT JOIN mtr_hops h
        ON h.trace_id = st.id
        AND h.time >= st.time
        AND h.time >= $1
        AND h.time < $2
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

    query_fun = cnpg_query(opts)
    rows_to_maps(query_fun.(query, [window.start, window.end, limit] ++ params))
  end

  defp window_agent_comparison(window_a, window_b, filters, opts) do
    result =
      if MtrWarehouse.enabled?() do
        MtrWarehouse.window_agent_comparison(window_a, window_b, compare_terms(filters), opts)
      else
        cnpg_window_agent_comparison(window_a, window_b, filters, opts)
      end

    case result do
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

  @sobelow_skip ["SQL.Query"]
  defp cnpg_window_agent_comparison(window_a, window_b, filters, opts) do
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

    cnpg_query(opts).(query, [window_a.start, window_a.end, window_b.start, window_b.end] ++ params)
  end

  defp build_compare_where(filters, start_idx, table_alias) do
    {conditions, params} = filters |> compare_terms() |> cnpg_conditions(start_idx, "#{table_alias}.")

    clause =
      case conditions do
        [] -> ""
        _ -> "AND " <> Enum.join(conditions, " AND ")
      end

    {clause, params}
  end

  # The Compare filters as terms, in the order CNPG has always applied them.
  defp compare_terms(filters) do
    target_terms =
      case Map.get(filters, :target_filter, "") do
        "" -> []
        target_filter -> [{:like_any, ["target", "target_ip"], to_string(target_filter)}]
      end

    agent_terms =
      case Map.get(filters, :agent_filter, "") do
        "" -> []
        agent_filter -> [{:like_any, ["agent_id"], to_string(agent_filter)}]
      end

    protocol_terms =
      case Map.get(filters, :protocol, "") do
        "" -> []
        protocol -> [{:eq, "protocol", protocol}]
      end

    reached_terms =
      case Map.get(filters, :reached, :any) do
        :any -> []
        reached? when is_boolean(reached?) -> [{:eq, "target_reached", reached?}]
      end

    target_terms ++ agent_terms ++ protocol_terms ++ reached_terms
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

  # Filter terms are the dialect-free model of every MTR filter:
  #
  #   {:like_any, [field, ...], text}   case-insensitive `%text%` on any field
  #   {:eq, field, value}               equality with a string or boolean
  #   {:any_eq, [{field, value}, ...]}  an OR of equalities
  #   {:time_range, start | nil, end | nil}
  #
  # `cnpg_conditions/3` renders them into the conditions and positional params
  # CNPG has always run; MtrWarehouse renders them for the warehouse.
  defp trace_filter_terms(target_filter, agent_filter, device_uid, device_ip) do
    # A nil filter has always rendered CNPG's pattern as "%%"; the term carries
    # the string both renderers interpolate.
    target_terms =
      if target_filter == "", do: [], else: [{:like_any, ["target", "target_ip"], to_string(target_filter)}]

    agent_terms = if agent_filter == "", do: [], else: [{:like_any, ["agent_id"], to_string(agent_filter)}]

    device_terms =
      case {device_uid, device_ip} do
        {uid, ip} when is_binary(uid) and uid != "" and is_binary(ip) and ip != "" ->
          [{:any_eq, [{"device_id", uid}, {"target_ip", ip}]}]

        {uid, _ip} when is_binary(uid) and uid != "" ->
          [{:eq, "device_id", uid}]

        {_uid, ip} when is_binary(ip) and ip != "" ->
          [{:eq, "target_ip", ip}]

        _ ->
          []
      end

    target_terms ++ agent_terms ++ device_terms
  end

  defp cnpg_conditions(terms, start_idx, prefix) do
    {conditions, params, _idx} =
      Enum.reduce(terms, {[], [], start_idx}, fn term, {conditions, params, idx} ->
        {condition, term_params} = cnpg_condition(term, idx, prefix)
        {conditions ++ [condition], params ++ term_params, idx + length(term_params)}
      end)

    {conditions, params}
  end

  defp cnpg_condition({:like_any, [field], text}, idx, prefix),
    do: {"#{cnpg_column(prefix, field)} ILIKE $#{idx}", ["%#{text}%"]}

  defp cnpg_condition({:like_any, fields, text}, idx, prefix) do
    condition = Enum.map_join(fields, " OR ", &"#{cnpg_column(prefix, &1)} ILIKE $#{idx}")
    {"(#{condition})", ["%#{text}%"]}
  end

  defp cnpg_condition({:eq, field, value}, idx, prefix), do: {"#{cnpg_column(prefix, field)} = $#{idx}", [value]}

  defp cnpg_condition({:any_eq, pairs}, idx, prefix) do
    {conditions, params} =
      pairs
      |> Enum.with_index(idx)
      |> Enum.map(fn {{field, value}, param_idx} -> {"#{cnpg_column(prefix, field)} = $#{param_idx}", value} end)
      |> Enum.unzip()

    {"(#{Enum.join(conditions, " OR ")})", params}
  end

  defp cnpg_condition({:time_range, start_dt, nil}, idx, prefix), do: {"#{prefix}time >= $#{idx}", [start_dt]}
  defp cnpg_condition({:time_range, nil, end_dt}, idx, prefix), do: {"#{prefix}time < $#{idx}", [end_dt]}

  defp cnpg_condition({:time_range, start_dt, end_dt}, idx, prefix),
    do: {"#{prefix}time >= $#{idx} AND #{prefix}time < $#{idx + 1}", [start_dt, end_dt]}

  defp cnpg_column(prefix, field), do: prefix <> Map.get(@safe_filter_columns, field, field)

  defp cnpg_query(opts), do: Keyword.get(opts, :cnpg_query, &Repo.query/2)

  defp rows_to_maps({:ok, %{rows: rows, columns: columns}}),
    do: {:ok, Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)}

  defp rows_to_maps({:error, reason}), do: {:error, reason}

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

  defp trace_terms_with_srql(target_filter, agent_filter, device_uid, device_ip, srql_query) do
    {srql_terms, srql_sort} = parse_srql_terms(srql_query)

    {trace_filter_terms(target_filter, agent_filter, device_uid, device_ip) ++ srql_terms, srql_sort}
  end

  defp parse_srql_terms(query) when is_binary(query) do
    query
    |> tokenize_srql()
    |> Enum.reduce({[], nil}, fn token, {terms, sort} ->
      token
      |> String.trim()
      |> maybe_parse_token(terms, sort)
    end)
  end

  defp parse_srql_terms(_), do: {[], nil}

  defp maybe_parse_token("", terms, sort), do: {terms, sort}

  defp maybe_parse_token(token, terms, sort) do
    cond do
      String.starts_with?(token, "in:") ->
        {terms, sort}

      String.starts_with?(token, "limit:") ->
        {terms, sort}

      String.starts_with?(token, "sort:") ->
        {terms, parse_sort_token(token) || sort}

      String.starts_with?(token, "time:") ->
        {terms ++ time_filter_terms(token), sort}

      String.contains?(token, ":") ->
        {terms ++ field_filter_terms(token), sort}

      true ->
        text = normalize_srql_value(token)

        if text == "" do
          {terms, sort}
        else
          {terms ++ [{:like_any, ["target", "target_ip", "agent_id", "check_name"], text}], sort}
        end
    end
  end

  defp field_filter_terms(token) do
    case String.split(token, ":", parts: 2) do
      [raw_field, raw_value] ->
        field = String.downcase(raw_field)
        value = normalize_srql_value(raw_value)
        filter_terms_by_field(field, value)

      _ ->
        []
    end
  end

  defp filter_terms_by_field("", _value), do: []

  defp filter_terms_by_field(_field, value) when not is_binary(value) or value == "", do: []

  defp filter_terms_by_field(field, value) do
    cond do
      not Map.has_key?(@safe_filter_columns, field) or not MapSet.member?(@allowed_filter_fields, field) ->
        []

      MapSet.member?(@boolean_filter_fields, field) ->
        case parse_boolean(value) do
          nil -> []
          bool_value -> [{:eq, field, bool_value}]
        end

      MapSet.member?(@exact_filter_fields, field) ->
        [{:eq, field, value}]

      true ->
        [{:like_any, [field], value}]
    end
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

  defp time_filter_terms("time:" <> raw_value) do
    raw_value
    |> normalize_srql_value()
    |> parse_time_range()
    |> case do
      {:ok, nil, nil} -> []
      {:ok, start_dt, end_dt} -> [{:time_range, start_dt, end_dt}]
      :error -> []
    end
  end

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
