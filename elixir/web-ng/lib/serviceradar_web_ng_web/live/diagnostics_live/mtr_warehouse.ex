defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse do
  @moduledoc """
  Warehouse (StarRocks) implementations of the MTR readers.

  Exactly one telemetry backend is active. With `analytics.starrocks.enabled`
  on, EventWriter writes MTR traces and hops to the warehouse and nothing to
  CNPG, so every MTR reader reads here and never the CNPG `mtr_traces` /
  `mtr_hops` hypertables, which stop receiving rows. With it off, the CNPG
  implementations in `MtrData`, the dashboard loaders and the Ash-backed pages
  are used unchanged. `enabled?/0` is the one switch; it is the global flag,
  not the per-dataset cutover list.

  Every query here mirrors its CNPG counterpart clause by clause and returns
  what `Repo.query/2` would -- `%{columns: [...], rows: [[...]]}` with values
  normalized to the types Postgrex decodes (a UTC `DateTime` with microsecond
  precision, a boolean, a list, a decoded JSON document, a float) -- so the
  callers shape both backends' answers with the same code and templates do not
  change. The translations and the places they cannot be literal are listed at
  the SQL builders. Result parity against a live warehouse is NOT yet proven:
  the parity harness (extend-starrocks-to-all-telemetry task 1.4) does not
  exist, so these readers ship with SQL-shape tests only.

  The Frontend is queried over the MySQL text protocol, which takes no bind
  parameters, so values reach it as literals. Every interpolated value is
  therefore either produced here (an integer, a `DateTime`, a boolean, a
  column name from a closed list) or a caller string validated as UTF-8
  without NUL and quoted with backslash and quote escaped. A filter value that
  fails validation is `{:error, :invalid_filter_value}`, which is where CNPG
  would also refuse it (Postgres rejects such text parameters).

  `:starrocks_query` in `opts` replaces `ServiceRadar.Analytics.StarRocks.Query.execute/1`
  (tests capture the SQL through it).
  """

  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Readers

  @list_trace_columns ~w(
    id time agent_id check_id check_name device_id target target_ip target_reached total_hops
    probed_hops last_responding_hop protocol tcp_port ip_version error
  )

  @detail_trace_columns ~w(
    id time agent_id gateway_id check_id check_name device_id target target_ip target_reached
    total_hops probed_hops last_responding_hop protocol tcp_port ip_version packet_size partition
    error tcp_handshake_ttl tcp_handshake_attempts tcp_syn_sent tcp_synack_received
    tcp_rst_received tcp_syn_unanswered tcp_syn_drop_pct tcp_syn_retransmits
    tcp_answered_after_retx tcp_ack_mismatch tcp_synack_duplicates tcp_handshake_rtt_min_us
    tcp_handshake_rtt_avg_us tcp_handshake_rtt_max_us tcp_server_response_us
  )

  @hop_columns ~w(
    id time hop_number addr hostname ecmp_addrs asn asn_org mpls_labels sent received loss_pct
    last_us avg_us min_us max_us stddev_us jitter_us jitter_worst_us jitter_interarrival_us
    unreachable_code reply_time_exceeded reply_unreachable reply_synack reply_rst
  )

  @compare_trace_columns ~w(id time agent_id target target_ip target_reached total_hops protocol ip_version)

  # Columns a caller may sort the paginated list by, mirroring MtrData's allowlist.
  @sort_fields ~w(time target target_ip agent_id protocol total_hops target_reached)

  # Columns a filter term may name. Every one is VARCHAR or BOOLEAN in the warehouse.
  @filter_fields ~w(target target_ip agent_id protocol check_name device_id target_reached error)

  @datetime_columns ~w(time earliest_time latest_time bucket_start bucket_end)
  @boolean_columns ~w(target_reached)
  @array_columns ~w(ecmp_addrs agent_ids)
  @json_columns ~w(mpls_labels)

  @one_second_us 1_000_000

  @doc "Whether MTR reads belong to the warehouse: the global `analytics.starrocks.enabled` flag."
  @spec enabled?() :: boolean()
  def enabled?, do: Readers.enabled?()

  # ---------------------------------------------------------------------------
  # Trace list, page, coverage
  # ---------------------------------------------------------------------------

  @doc """
  The newest `limit` traces matching `terms`, each with its reached terminal
  hop's destination figures. Mirrors `MtrData.list_traces/1`.
  """
  @spec list_traces([tuple()], pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_traces(terms, limit, opts \\ []) when is_integer(limit) and limit > 0 do
    with {:ok, where} <- where_clause(terms, "") do
      sql = """
      WITH selected_traces AS (
        SELECT #{columns(@list_trace_columns)}
        FROM #{table("mtr_traces")}
        #{where}
        ORDER BY `time` DESC, `id` DESC
        LIMIT #{limit}
      ),
      terminal_hops AS (
        SELECT trace_id, sent, received, avg_us
        FROM (
          SELECT h.trace_id, h.sent, h.received, h.avg_us,
                 ROW_NUMBER() OVER (
                   PARTITION BY h.trace_id
                   ORDER BY h.`time` DESC, h.`id` DESC
                 ) AS terminal_rank
          FROM #{table("mtr_hops")} h
          INNER JOIN selected_traces st
            ON st.`id` = h.trace_id
            AND st.target_reached
            AND h.hop_number = st.total_hops
            AND h.`time` >= st.`time`
          WHERE h.`time` >= (SELECT MIN(`time`) FROM selected_traces)
        ) ranked_terminal_hops
        WHERE terminal_rank = 1
      )
      SELECT #{aliased(@list_trace_columns, "st")},
             destination.sent AS destination_sent,
             destination.received AS destination_received,
             destination.avg_us AS destination_avg_us,
             CASE
               WHEN destination.sent > 0 THEN
                 100.0 * CAST(destination.sent - destination.received AS DOUBLE) / CAST(destination.sent AS DOUBLE)
             END AS destination_loss_pct
      FROM selected_traces st
      LEFT JOIN terminal_hops destination ON destination.trace_id = st.`id`
      ORDER BY st.`time` DESC, st.`id` DESC
      """

      run(opts, sql)
    end
  end

  @doc """
  One page of traces and the total matching count, as `{:ok, rows, total}`.
  Mirrors the two statements of `MtrData.list_traces_paginated/1`.

  The sort column is ordered NULLS LAST ascending and NULLS FIRST descending,
  which is Postgres's default and not StarRocks's.
  """
  @spec trace_page([tuple()], {String.t(), String.t()}, pos_integer(), non_neg_integer(), keyword()) ::
          {:ok, [map()], non_neg_integer() | nil} | {:error, term()}
  def trace_page(terms, sort, per_page, offset, opts \\ [])
      when is_integer(per_page) and per_page > 0 and is_integer(offset) and offset >= 0 do
    with {:ok, where} <- where_clause(terms, "") do
      sql = """
      SELECT #{columns(@list_trace_columns)}
      FROM #{table("mtr_traces")}
      #{where}
      ORDER BY #{page_order(sort)}
      LIMIT #{per_page} OFFSET #{offset}
      """

      count_sql = """
      SELECT COUNT(*) AS total
      FROM #{table("mtr_traces")}
      #{where}
      """

      with {:ok, %{rows: rows, columns: columns}} <- run(opts, sql),
           {:ok, %{rows: [[total]]}} <- run(opts, count_sql) do
        {:ok, Enum.map(rows, &row_map(columns, &1)), total}
      else
        {:ok, result} -> {:error, {:unexpected_result, result}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Trace, reached and failed counts and the time span for `terms`. Mirrors `MtrData.trace_coverage/1`."
  @spec trace_coverage([tuple()], keyword()) :: {:ok, map()} | {:error, term()}
  def trace_coverage(terms, opts \\ []) do
    with {:ok, where} <- where_clause(terms, "") do
      sql = """
      SELECT COUNT(*) AS trace_count,
             COUNT(CASE WHEN target_reached THEN 1 END) AS reached_count,
             COUNT(CASE WHEN NOT target_reached THEN 1 END) AS failed_count,
             MIN(`time`) AS earliest_time,
             MAX(`time`) AS latest_time
      FROM #{table("mtr_traces")}
      #{where}
      """

      run(opts, sql)
    end
  end

  # ---------------------------------------------------------------------------
  # Trace detail
  # ---------------------------------------------------------------------------

  @doc """
  One trace and its hops, as `{:ok, trace, hops}`. Mirrors `MtrData.get_trace_detail/3`.

  `trace_id` is cast with `Ecto.UUID.cast/1`, so only its canonical form is
  ever quoted; one that is not a UUID is `{:error, :not_found}`, as on CNPG.
  With `time`, the trace lookup is bounded to the second holding it, which
  names the same row as CNPG's `time = $2` (the id is unique) while not
  depending on the warehouse keeping sub-second precision. The hop lookup is
  bounded below by the trace's time, as on CNPG: a hop is never older than
  its trace, and the bound prunes day partitions.

  `hop_limit:` caps the hops returned (the Ash-backed pages read at most 256).
  """
  @spec trace_detail(String.t(), DateTime.t() | nil, keyword()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def trace_detail(trace_id, time, opts \\ []) when is_binary(trace_id) do
    with {:ok, uuid} <- trace_id |> Ecto.UUID.cast() |> ok_or(:not_found),
         {:ok, %{rows: [trace_row], columns: trace_cols}} <- run(opts, trace_sql(uuid, time)),
         trace = row_map(trace_cols, trace_row),
         %DateTime{} = trace_time <- trace["time"],
         {:ok, %{rows: hop_rows, columns: hop_cols}} <-
           run(opts, hops_sql(uuid, trace_time, Keyword.get(opts, :hop_limit))) do
      {:ok, trace, Enum.map(hop_rows, &row_map(hop_cols, &1))}
    else
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_trace_row, other}}
    end
  end

  defp trace_sql(uuid, time) do
    """
    SELECT #{columns(@detail_trace_columns)}
    FROM #{table("mtr_traces")}
    WHERE `id` = #{string(uuid)}#{trace_time_bound(time)}
    LIMIT 1
    """
  end

  defp trace_time_bound(%DateTime{} = time) do
    second = time |> utc() |> DateTime.truncate(:second)

    " AND `time` >= #{datetime(second)} AND `time` < #{datetime(DateTime.add(second, 1, :second))}"
  end

  defp trace_time_bound(_time), do: ""

  defp hops_sql(uuid, %DateTime{} = trace_time, limit) do
    """
    SELECT #{columns(@hop_columns)}
    FROM #{table("mtr_hops")}
    WHERE trace_id = #{string(uuid)} AND `time` >= #{datetime(trace_time)}
    ORDER BY hop_number ASC, `time` DESC, `id` DESC#{limit_clause(limit)}
    """
  end

  defp limit_clause(limit) when is_integer(limit) and limit > 0, do: "\nLIMIT #{limit}"
  defp limit_clause(_limit), do: ""

  @recent_trace_days 7

  @doc """
  The newest `limit` traces for the Compare page's picker, with the columns
  its Ash read maps, from the last #{@recent_trace_days} days. Unlike the CNPG
  read it is time-bounded, because a newest-N read without a partition bound
  can scan every partition of the table.
  """
  @spec recent_traces(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recent_traces(limit, opts \\ []) when is_integer(limit) and limit > 0 do
    # Bounded so the newest-N read prunes to recent day partitions instead of
    # scanning every partition the table holds.
    since = DateTime.add(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0), -@recent_trace_days, :day)

    sql = """
    SELECT #{columns(@compare_trace_columns)}
    FROM #{table("mtr_traces")}
    WHERE `time` >= #{datetime(since)}
    ORDER BY `time` DESC
    LIMIT #{limit}
    """

    with {:ok, %{rows: rows, columns: columns}} <- run(opts, sql) do
      {:ok, Enum.map(rows, &row_map(columns, &1))}
    end
  end

  @doc """
  Recent positive latency samples for `addrs`, newest first, as maps with
  `:addr`, `:time` and `:avg_us` -- the fields the trace page's sparklines
  read off the Ash hop records. Mirrors that Ash read: `addr IN addrs`,
  `avg_us > 0`, `time >= since`, `time DESC`, `limit`.
  """
  @spec hop_latency_points([String.t()], DateTime.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def hop_latency_points(addrs, %DateTime{} = since, limit, opts \\ [])
      when is_list(addrs) and is_integer(limit) and limit > 0 do
    case addrs |> Enum.filter(&valid_text?/1) |> Enum.uniq() do
      [] ->
        {:ok, []}

      valid ->
        sql = """
        SELECT addr, `time`, avg_us
        FROM #{table("mtr_hops")}
        WHERE addr IN (#{Enum.map_join(valid, ", ", &string/1)})
          AND avg_us IS NOT NULL
          AND avg_us > 0
          AND `time` >= #{datetime(since)}
        ORDER BY `time` DESC
        LIMIT #{limit}
        """

        with {:ok, %{rows: rows, columns: columns}} <- run(opts, sql) do
          {:ok,
           Enum.map(rows, fn row ->
             map = row_map(columns, row)
             %{addr: map["addr"], time: map["time"], avg_us: map["avg_us"]}
           end)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Compare windows
  # ---------------------------------------------------------------------------

  @doc """
  Window summary row. Mirrors `MtrData`'s `window_summary/2`.

  CNPG computes the responding depth of an unreached trace without
  `last_responding_hop` in a correlated scalar subquery (`... HAVING COUNT(*) > 0`).
  Here it is a pre-aggregated `hop_depth` join: a trace with hops gets
  `COALESCE(MAX(hop_number) of replying hops, 0)`, a trace without hops gets no
  row and so NULL, which is what the subquery returns in each case. The join
  only aggregates traces that reach that branch of the CASE, and its hop scan
  carries the window's lower bound, which `h.time >= st.time` already implies.
  """
  @spec window_summary(map(), [tuple()], keyword()) :: {:ok, map()} | {:error, term()}
  def window_summary(%{start: start_at, end: end_at}, terms, opts \\ []) do
    with {:ok, filters} <- and_clause(terms, "t.") do
      reached_dest = "th.received > 0 AND th.avg_us IS NOT NULL"

      sql = """
      WITH selected_traces AS (
        SELECT `id`, `time`, agent_id, target, target_ip, target_reached, total_hops,
               last_responding_hop, protocol
        FROM #{table("mtr_traces")} t
        WHERE t.`time` >= #{datetime(start_at)} AND t.`time` < #{datetime(end_at)}
        #{filters}
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
              ORDER BY h.`time` DESC, h.`id` DESC
            ) AS terminal_rank
          FROM #{table("mtr_hops")} h
          INNER JOIN selected_traces st
            ON st.`id` = h.trace_id
            AND st.target_reached
            AND h.hop_number = st.total_hops
            AND h.`time` >= st.`time`
          WHERE h.`time` >= #{datetime(start_at)} AND h.`time` < #{datetime(end_at)}
        ) terminal_candidates
        WHERE terminal_rank = 1
      ),
      hop_depth AS (
        SELECT h.trace_id,
               COALESCE(MAX(CASE WHEN h.received > 0 THEN h.hop_number END), 0) AS responding_depth
        FROM #{table("mtr_hops")} h
        INNER JOIN selected_traces st
          ON st.`id` = h.trace_id
          AND h.`time` >= st.`time`
          AND NOT COALESCE(st.target_reached, FALSE)
          AND st.last_responding_hop IS NULL
        WHERE h.`time` >= #{datetime(start_at)}
        GROUP BY h.trace_id
      )
      SELECT
        COUNT(st.`id`) AS trace_count,
        COUNT(CASE WHEN st.target_reached THEN st.`id` END) AS reached_count,
        COUNT(CASE WHEN NOT st.target_reached THEN st.`id` END) AS failed_count,
        CAST(COALESCE(AVG(NULLIF(
          CASE
            WHEN st.target_reached THEN st.total_hops
            ELSE COALESCE(st.last_responding_hop, hd.responding_depth, st.total_hops)
          END,
          0
        )), 0) AS DOUBLE) AS avg_hops,
        CASE
          WHEN COALESCE(SUM(CASE WHEN #{reached_dest} THEN th.received END), 0) > 0
          THEN
            CAST(SUM(CASE WHEN #{reached_dest} THEN CAST(th.avg_us AS BIGINT) * th.received END) AS DOUBLE) /
            CAST(SUM(CASE WHEN #{reached_dest} THEN th.received END) AS DOUBLE)
        END AS avg_destination_us,
        CASE
          WHEN COALESCE(SUM(CASE WHEN th.sent > 0 THEN th.sent END), 0) > 0
          THEN
            100.0 * CAST(
              SUM(CASE WHEN th.sent > 0 THEN th.sent END) -
              SUM(CASE WHEN th.sent > 0 THEN COALESCE(th.received, 0) END)
            AS DOUBLE) / CAST(SUM(CASE WHEN th.sent > 0 THEN th.sent END) AS DOUBLE)
        END AS destination_loss_pct,
        COUNT(th.trace_id) AS endpoint_sample_count,
        COUNT(DISTINCT st.agent_id) AS agent_count,
        COUNT(DISTINCT COALESCE(NULLIF(st.target_ip, ''), st.target)) AS target_count
      FROM selected_traces st
      LEFT JOIN terminal_hops th ON th.trace_id = st.`id`
      LEFT JOIN hop_depth hd ON hd.trace_id = st.`id`
      """

      run(opts, sql)
    end
  end

  @doc """
  Reachability timeline buckets for a window. Mirrors `MtrData`'s `window_timeline/3`.

  CNPG builds the buckets with `generate_series` over `start + idx * step`,
  `step = GREATEST((end - start) / n, interval '1 second')`, and LEFT JOINs the
  traces on `[bucket_start, bucket_start + step)`. The same boundaries are
  computed here (see `timeline_buckets/3`) and sent as a literal bucket table,
  so the warehouse does not need a series generator. As on CNPG, traces are
  bounded by the buckets, not by the window's end: when the rounded step
  overshoots, the last bucket ends after `end` and counts what falls in it.
  """
  @spec window_timeline(map(), [tuple()], pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def window_timeline(%{start: start_at, end: end_at}, terms, bucket_count, opts \\ [])
      when is_integer(bucket_count) and bucket_count > 0 do
    with {:ok, filters} <- and_clause(terms, "t.") do
      buckets = timeline_buckets(start_at, end_at, bucket_count)
      {_idx, first_start, _end} = List.first(buckets)
      {_idx, _start, last_end} = List.last(buckets)

      bucket_rows =
        Enum.map_join(buckets, "\n    UNION ALL\n", fn {idx, bucket_start, bucket_end} ->
          "    SELECT #{idx} AS idx, CAST(#{datetime(bucket_start)} AS DATETIME) AS bucket_start, " <>
            "CAST(#{datetime(bucket_end)} AS DATETIME) AS bucket_end"
        end)

      sql = """
      WITH buckets AS (
      #{bucket_rows}
      ),
      bucket_counts AS (
        SELECT
          b.idx,
          COUNT(t.`id`) AS trace_count,
          COUNT(CASE WHEN t.target_reached THEN t.`id` END) AS reached_count,
          COUNT(CASE WHEN NOT t.target_reached THEN t.`id` END) AS failed_count
        FROM #{table("mtr_traces")} t
        INNER JOIN buckets b
          ON t.`time` >= b.bucket_start
         AND t.`time` < b.bucket_end
        WHERE t.`time` >= #{datetime(first_start)} AND t.`time` < #{datetime(last_end)}
        #{filters}
        GROUP BY b.idx
      )
      SELECT
        b.bucket_start,
        b.bucket_end,
        COALESCE(c.trace_count, 0) AS trace_count,
        COALESCE(c.reached_count, 0) AS reached_count,
        COALESCE(c.failed_count, 0) AS failed_count
      FROM buckets b
      LEFT JOIN bucket_counts c ON c.idx = b.idx
      ORDER BY b.bucket_start ASC
      """

      run(opts, sql)
    end
  end

  @doc """
  The `[{idx, bucket_start, bucket_end}]` boundaries CNPG's timeline generates:
  `step` is the window divided by `bucket_count`, rounded to the microsecond as
  Postgres rounds interval division, and at least one second.
  """
  @spec timeline_buckets(DateTime.t(), DateTime.t(), pos_integer()) :: [{non_neg_integer(), DateTime.t(), DateTime.t()}]
  def timeline_buckets(%DateTime{} = start_at, %DateTime{} = end_at, bucket_count)
      when is_integer(bucket_count) and bucket_count > 0 do
    span_us = DateTime.diff(end_at, start_at, :microsecond)
    step_us = max(round(span_us / bucket_count), @one_second_us)

    Enum.map(0..(bucket_count - 1), fn idx ->
      bucket_start = DateTime.add(start_at, idx * step_us, :microsecond)
      {idx, bucket_start, DateTime.add(bucket_start, step_us, :microsecond)}
    end)
  end

  @doc """
  Dominant route signatures in a window. Mirrors `MtrData`'s `window_route_signatures/3`.

  `array_agg ... ORDER BY`, `array_to_string` and `(array_agg(...))[1]` become
  `array_agg ... ORDER BY`, `array_join` and `element_at(array_agg(...), 1)`;
  `array_agg(DISTINCT agent_id ORDER BY agent_id)` becomes
  `array_sort(array_distinct(array_agg(agent_id)))`, equal because `agent_id`
  is never NULL. `md5` is lowercase hex on both. As on CNPG, hops that share a
  hop number, and signatures or representatives that tie, are in no defined
  order.
  """
  @spec window_route_signatures(map(), [tuple()], pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def window_route_signatures(%{start: start_at, end: end_at}, terms, limit, opts \\ [])
      when is_integer(limit) and limit > 0 do
    with {:ok, filters} <- and_clause(terms, "t.") do
      sql = """
      WITH selected_traces AS (
        SELECT `id`, `time`, agent_id, target, target_ip, target_reached, total_hops, protocol
        FROM #{table("mtr_traces")} t
        WHERE t.`time` >= #{datetime(start_at)} AND t.`time` < #{datetime(end_at)}
        #{filters}
      ),
      paths AS (
        SELECT
          st.`id` AS trace_id,
          st.`time` AS `time`,
          st.agent_id,
          st.target,
          st.target_ip,
          st.target_reached,
          array_agg(COALESCE(NULLIF(h.addr, ''), '*') ORDER BY h.hop_number) AS hop_addrs
        FROM selected_traces st
        LEFT JOIN #{table("mtr_hops")} h
          ON h.trace_id = st.`id`
          AND h.`time` >= st.`time`
          AND h.`time` >= #{datetime(start_at)}
          AND h.`time` < #{datetime(end_at)}
        GROUP BY st.`id`, st.`time`, st.agent_id, st.target, st.target_ip, st.target_reached
      ),
      signed_paths AS (
        SELECT
          trace_id,
          `time`,
          agent_id,
          target,
          target_ip,
          target_reached,
          CASE
            WHEN hop_addrs IS NULL THEN '*'
            ELSE array_join(hop_addrs, '>')
          END AS path_signature,
          CASE
            WHEN hop_addrs IS NULL THEN '*'
            ELSE array_join(hop_addrs, ' -> ')
          END AS path_preview
        FROM paths
      )
      SELECT
        md5(path_signature) AS signature_id,
        path_preview,
        COUNT(*) AS trace_count,
        COUNT(CASE WHEN target_reached THEN 1 END) AS reached_count,
        COUNT(DISTINCT agent_id) AS agent_count,
        element_at(array_agg(trace_id ORDER BY `time` DESC), 1) AS representative_trace_id,
        MAX(`time`) AS latest_time,
        array_sort(array_distinct(array_agg(agent_id))) AS agent_ids
      FROM signed_paths
      GROUP BY path_signature, path_preview
      ORDER BY COUNT(*) DESC, MAX(`time`) DESC
      LIMIT #{limit}
      """

      run(opts, sql)
    end
  end

  @doc "Per-agent trace counts in two windows. Mirrors `MtrData`'s `window_agent_comparison/3`."
  @spec window_agent_comparison(map(), map(), [tuple()], keyword()) :: {:ok, map()} | {:error, term()}
  def window_agent_comparison(%{start: a_start, end: a_end}, %{start: b_start, end: b_end}, terms, opts \\ []) do
    with {:ok, filters} <- and_clause(terms, "t.") do
      in_a = "t.`time` >= #{datetime(a_start)} AND t.`time` < #{datetime(a_end)}"
      in_b = "t.`time` >= #{datetime(b_start)} AND t.`time` < #{datetime(b_end)}"

      sql = """
      WITH selected_traces AS (
        SELECT
          CASE
            WHEN #{in_a} THEN 'a'
            WHEN #{in_b} THEN 'b'
          END AS side,
          t.agent_id,
          t.target_reached
        FROM #{table("mtr_traces")} t
        WHERE ((#{in_a}) OR (#{in_b}))
        #{filters}
      )
      SELECT
        agent_id,
        COUNT(CASE WHEN side = 'a' THEN 1 END) AS a_trace_count,
        COUNT(CASE WHEN side = 'a' AND target_reached THEN 1 END) AS a_reached_count,
        COUNT(CASE WHEN side = 'b' THEN 1 END) AS b_trace_count,
        COUNT(CASE WHEN side = 'b' AND target_reached THEN 1 END) AS b_reached_count
      FROM selected_traces
      WHERE side IS NOT NULL
      GROUP BY agent_id
      ORDER BY agent_id ASC
      LIMIT 50
      """

      run(opts, sql)
    end
  end

  # ---------------------------------------------------------------------------
  # Dashboard
  # ---------------------------------------------------------------------------

  @doc """
  The dashboard MTR card row since `cutoff`. Mirrors the dashboard's
  `mtr_timeseries_summary/1`: one positional row of path, endpoint, loss and
  latency sample counts, loss %, latency ms and degraded count.
  """
  @spec dashboard_summary(DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dashboard_summary(%DateTime{} = cutoff, opts \\ []) do
    latency_rows = "dh.avg_us IS NOT NULL AND dh.received > 0"

    sql = """
    WITH selected_traces AS (
      SELECT `id`, `time`, target_reached, total_hops
      FROM #{table("mtr_traces")}
      WHERE `time` >= #{datetime(cutoff)}
    ),
    destination_hops AS (
      SELECT trace_id, sent, received, avg_us
      FROM (
        SELECT
          h.trace_id,
          h.sent,
          h.received,
          h.avg_us,
          ROW_NUMBER() OVER (
            PARTITION BY h.trace_id
            ORDER BY h.`time` DESC, h.`id` DESC
          ) AS terminal_rank
        FROM #{table("mtr_hops")} h
        INNER JOIN selected_traces st ON st.`id` = h.trace_id
          AND st.target_reached
          AND h.hop_number = st.total_hops
          AND h.`time` >= st.`time`
        WHERE h.`time` >= #{datetime(cutoff)}
      ) terminal_candidates
      WHERE terminal_rank = 1
    )
    SELECT
      COUNT(st.`id`) AS path_count,
      COUNT(dh.trace_id) AS endpoint_sample_count,
      COUNT(CASE WHEN dh.sent > 0 THEN dh.trace_id END) AS loss_sample_count,
      COUNT(CASE WHEN #{latency_rows} THEN dh.trace_id END) AS latency_sample_count,
      #{loss_pct_sql("dh")} AS avg_loss_pct,
      #{latency_ms_sql("dh")} AS avg_latency_ms,
      COUNT(CASE
        WHEN NOT st.target_reached
          OR (dh.sent > dh.received)
          OR (#{latency_rows} AND dh.avg_us > 100000)
        THEN st.`id`
      END) AS degraded_count
    FROM selected_traces st
    LEFT JOIN destination_hops dh ON dh.trace_id = st.`id`
    """

    run(opts, sql)
  end

  @doc """
  The dashboard latency (`:latency_ms`) or packet-loss (`:loss_pct`)
  sparkline: the newest `limit` buckets of `bucket_seconds` since `cutoff`,
  oldest first, as `[bucket, value]`. Mirrors the dashboard's
  `mtr_timeseries_sparkline/2`.

  Timescale's `time_bucket` and StarRocks's `time_slice` both align these
  bucket widths (whole divisors of a day) to midnight UTC, so they cut the
  same buckets.
  """
  @spec destination_sparkline(DateTime.t(), pos_integer(), :latency_ms | :loss_pct, pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def destination_sparkline(%DateTime{} = cutoff, bucket_seconds, metric, limit, opts \\ [])
      when is_integer(bucket_seconds) and bucket_seconds > 0 and metric in [:latency_ms, :loss_pct] and
             is_integer(limit) and limit > 0 do
    {value_expr, denominator_expr} = sparkline_value(metric)

    sql = """
    WITH destination_hops AS (
      SELECT trace_time, sent, received, avg_us
      FROM (
        SELECT
          t.`time` AS trace_time,
          h.`time` AS hop_time,
          h.`id` AS hop_id,
          h.trace_id,
          h.sent,
          h.received,
          h.avg_us,
          ROW_NUMBER() OVER (
            PARTITION BY h.trace_id
            ORDER BY h.`time` DESC, h.`id` DESC
          ) AS terminal_rank
        FROM #{table("mtr_traces")} t
        INNER JOIN #{table("mtr_hops")} h
          ON h.trace_id = t.`id`
          AND t.target_reached
          AND h.hop_number = t.total_hops
          AND h.`time` >= t.`time`
        WHERE t.`time` >= #{datetime(cutoff)}
          AND h.`time` >= #{datetime(cutoff)}
      ) terminal_candidates
      WHERE terminal_rank = 1
    )
    SELECT bucket, value
    FROM (
      SELECT
        time_slice(h.trace_time, INTERVAL #{bucket_seconds} SECOND) AS bucket,
        #{value_expr} AS value
      FROM destination_hops h
      GROUP BY 1
      HAVING #{denominator_expr} > 0
      ORDER BY 1 DESC
      LIMIT #{limit}
    ) recent
    ORDER BY bucket ASC
    """

    run(opts, sql)
  end

  defp sparkline_value(:latency_ms) do
    {latency_ms_sql("h"), "SUM(CASE WHEN h.avg_us IS NOT NULL AND h.received > 0 THEN h.received END)"}
  end

  defp sparkline_value(:loss_pct) do
    {loss_pct_sql("h"), "SUM(CASE WHEN h.sent > 0 THEN h.sent END)"}
  end

  # `100.0 * (SUM(sent) - SUM(received)) / NULLIF(SUM(sent), 0)` over rows with
  # probes sent: the summed-probe ratio, never a mean of per-hop percentages.
  # Like the dashboard's CNPG SQL, a NULL `received` is skipped by SUM rather
  # than counted as zero (the Compare summary, which COALESCEs, spells its own).
  defp loss_pct_sql(alias_name) do
    sent = "SUM(CASE WHEN #{alias_name}.sent > 0 THEN #{alias_name}.sent END)"
    received = "SUM(CASE WHEN #{alias_name}.sent > 0 THEN #{alias_name}.received END)"

    "100.0 * CAST(#{sent} - #{received} AS DOUBLE) / NULLIF(CAST(#{sent} AS DOUBLE), 0)"
  end

  # Reply-weighted mean RTT in ms: SUM(avg_us * received) / SUM(received) / 1000.
  defp latency_ms_sql(alias_name) do
    rows = "#{alias_name}.avg_us IS NOT NULL AND #{alias_name}.received > 0"
    weighted = "CAST(#{alias_name}.avg_us AS BIGINT) * #{alias_name}.received"

    "CAST(SUM(CASE WHEN #{rows} THEN #{weighted} END) AS DOUBLE) / " <>
      "NULLIF(CAST(SUM(CASE WHEN #{rows} THEN #{alias_name}.received END) AS DOUBLE), 0) / 1000.0"
  end

  # ---------------------------------------------------------------------------
  # Filter terms
  # ---------------------------------------------------------------------------

  # Terms are MtrData's dialect-free filter model; its CNPG renderer produces
  # the where-clauses CNPG always ran, this one their warehouse spelling.
  # ILIKE becomes LOWER(col) LIKE LOWER(pattern): StarRocks has no ILIKE, and
  # the pattern keeps CNPG's `%value%` with the caller's own wildcards intact.
  defp where_clause(terms, prefix) do
    with {:ok, conditions} <- conditions(terms, prefix) do
      case conditions do
        [] -> {:ok, ""}
        _ -> {:ok, "WHERE " <> Enum.join(conditions, " AND ")}
      end
    end
  end

  defp and_clause(terms, prefix) do
    with {:ok, conditions} <- conditions(terms, prefix) do
      case conditions do
        [] -> {:ok, ""}
        _ -> {:ok, "AND " <> Enum.join(conditions, " AND ")}
      end
    end
  end

  defp conditions(terms, prefix) when is_list(terms) do
    if Enum.all?(terms, &valid_term?/1) do
      {:ok, Enum.map(terms, &condition(&1, prefix))}
    else
      {:error, :invalid_filter_value}
    end
  end

  defp valid_term?({:like_any, [_ | _] = fields, text}), do: Enum.all?(fields, &filter_field?/1) and valid_text?(text)

  defp valid_term?({:eq, field, value}) when is_boolean(value), do: filter_field?(field)
  defp valid_term?({:eq, field, value}), do: filter_field?(field) and valid_text?(value)

  defp valid_term?({:any_eq, [_ | _] = pairs}),
    do: Enum.all?(pairs, fn {field, value} -> valid_term?({:eq, field, value}) end)

  defp valid_term?({:time_range, start_at, end_at}),
    do: datetime_or_nil?(start_at) and datetime_or_nil?(end_at) and not (is_nil(start_at) and is_nil(end_at))

  defp valid_term?(_term), do: false

  defp filter_field?(field), do: field in @filter_fields

  defp datetime_or_nil?(nil), do: true
  defp datetime_or_nil?(%DateTime{}), do: true
  defp datetime_or_nil?(_value), do: false

  defp condition({:like_any, [field], text}, prefix), do: like(prefix, field, text)

  defp condition({:like_any, fields, text}, prefix),
    do: "(" <> Enum.map_join(fields, " OR ", &like(prefix, &1, text)) <> ")"

  defp condition({:eq, field, true}, prefix), do: "#{column(prefix, field)} = TRUE"
  defp condition({:eq, field, false}, prefix), do: "#{column(prefix, field)} = FALSE"
  defp condition({:eq, field, value}, prefix), do: "#{column(prefix, field)} = #{string(value)}"

  defp condition({:any_eq, pairs}, prefix),
    do: "(" <> Enum.map_join(pairs, " OR ", fn {field, value} -> condition({:eq, field, value}, prefix) end) <> ")"

  defp condition({:time_range, start_at, nil}, prefix), do: "#{column(prefix, "time")} >= #{datetime(start_at)}"
  defp condition({:time_range, nil, end_at}, prefix), do: "#{column(prefix, "time")} < #{datetime(end_at)}"

  defp condition({:time_range, start_at, end_at}, prefix) do
    "#{column(prefix, "time")} >= #{datetime(start_at)} AND #{column(prefix, "time")} < #{datetime(end_at)}"
  end

  defp like(prefix, field, text), do: "LOWER(#{column(prefix, field)}) LIKE LOWER(#{string("%#{text}%")})"

  defp page_order({field, dir}) do
    field = if field in @sort_fields, do: field, else: "time"
    dir = if String.upcase(to_string(dir)) == "ASC", do: "ASC", else: "DESC"
    nulls = if dir == "ASC", do: "NULLS LAST", else: "NULLS FIRST"

    if field == "time" do
      "`time` #{dir}, `id` #{dir}"
    else
      "`#{field}` #{dir} #{nulls}, `time` #{dir}, `id` #{dir}"
    end
  end

  defp page_order(_sort), do: page_order({"time", "DESC"})

  # ---------------------------------------------------------------------------
  # Literals, identifiers, execution
  # ---------------------------------------------------------------------------

  defp table(name), do: Env.table(name)

  defp columns(names), do: Enum.map_join(names, ", ", &"`#{&1}`")

  defp aliased(names, prefix), do: Enum.map_join(names, ", ", &"#{prefix}.`#{&1}` AS `#{&1}`")

  defp column("", field), do: "`#{field}`"
  defp column(prefix, field), do: "#{prefix}`#{field}`"

  defp valid_text?(value) when is_binary(value), do: String.valid?(value) and not String.contains?(value, <<0>>)
  defp valid_text?(_value), do: false

  # Backslash first, so the escape added for a quote is not itself doubled.
  defp string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end

  # Warehouse DATETIME columns hold UTC wall-clock time, so a bound is the UTC
  # wall clock with no zone suffix, keeping its microseconds.
  defp datetime(%DateTime{} = value) do
    "'#{value |> utc() |> DateTime.to_naive() |> NaiveDateTime.to_string()}'"
  end

  defp utc(%DateTime{} = value), do: DateTime.shift_zone!(value, "Etc/UTC")

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp run(opts, sql) do
    query = Keyword.get(opts, :starrocks_query, &Query.execute/1)

    with :ok <- CatalogAllowlist.assert_sql_executable(sql) do
      case query.(sql) do
        {:ok, %{rows: rows} = result} when is_list(rows) -> {:ok, normalize(result)}
        {:ok, other} -> {:error, {:unexpected_result, other}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

  # ---------------------------------------------------------------------------
  # Result normalization to the Postgrex types the CNPG readers produce
  # ---------------------------------------------------------------------------

  defp normalize(%{rows: rows} = result) do
    columns = Map.get(result, :columns) || []

    rows =
      Enum.map(rows, fn row ->
        if length(columns) == length(row) do
          columns |> Enum.zip(row) |> Enum.map(fn {column, value} -> normalize_value(column, value) end)
        else
          Enum.map(row, &normalize_value(nil, &1))
        end
      end)

    result |> Map.put(:rows, rows) |> Map.put(:columns, columns)
  end

  defp normalize_value(_column, nil), do: nil
  defp normalize_value(column, value) when column in @datetime_columns, do: to_datetime(value)
  defp normalize_value(column, value) when column in @boolean_columns, do: to_boolean(value)
  defp normalize_value(column, value) when column in @array_columns, do: decode_document(value)
  defp normalize_value(column, value) when column in @json_columns, do: decode_document(value)
  defp normalize_value(_column, %Decimal{} = value), do: Decimal.to_float(value)
  defp normalize_value(_column, value), do: value

  # Postgrex decodes timestamptz as a UTC DateTime with microsecond precision.
  defp to_datetime(%DateTime{} = value), do: value |> utc() |> usec()
  defp to_datetime(%NaiveDateTime{} = value), do: value |> DateTime.from_naive!("Etc/UTC") |> usec()

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        to_datetime(datetime)

      {:error, _reason} ->
        case value |> String.replace(" ", "T", global: false) |> NaiveDateTime.from_iso8601() do
          {:ok, naive} -> to_datetime(naive)
          {:error, _reason} -> value
        end
    end
  end

  defp to_datetime(value), do: value

  defp usec(%DateTime{microsecond: {us, _precision}} = value), do: %{value | microsecond: {us, 6}}

  # A warehouse BOOLEAN arrives over the MySQL protocol as TINYINT.
  defp to_boolean(value) when is_boolean(value), do: value
  defp to_boolean(value) when value in [1, "1", "true"], do: true
  defp to_boolean(value) when value in [0, "0", "false"], do: false
  defp to_boolean(value), do: value

  # ARRAY and JSON columns arrive as their JSON text unless the driver already
  # decoded them; text that is not JSON is passed through rather than dropped.
  defp decode_document(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_document(value), do: value
end
