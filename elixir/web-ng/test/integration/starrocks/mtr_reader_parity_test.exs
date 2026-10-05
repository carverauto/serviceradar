defmodule ServiceRadarWebNGWeb.DashboardLive.MtrReaderParityTest do
  @moduledoc """
  Reader-level parity for the MTR warehouse readers: the same synthetic traces
  and hops are seeded into a throwaway CNPG database and the StarRocks
  warehouse, every `MtrData` reader is run against both, and the answers are
  compared.

  This is the Elixir tier the extend-starrocks-to-all-telemetry issue asked
  for, chosen over extending the Rust harness (`//integration_tests/srql_parity`)
  with an Elixir-driven step: `MtrData` and `MtrWarehouse` render their SQL in
  Elixir, not SRQL, so the Rust harness cannot execute their statements
  without a second copy of the SQL that would drift from the product; here the
  product's own readers run, through their `:cnpg_query` and
  `:starrocks_query` seams, against real databases. The backend is the global
  `analytics.starrocks.enabled` flag, so each side runs with the flag set for
  its backend (`with_backend/2`); the module is `async: false` and its Bazel
  target runs only this file, so no other test can observe the switch
  mid-call. The SRQL `in:mtr_*` shapes stay in the Rust inventory.

  What is compared:

  * `MtrData.list_traces/1`, `list_traces_paginated/1`, `trace_coverage/1`,
    `get_trace_detail/3` and `compare_windows/1` (which covers the Compare
    summary, timeline, route signatures and agent comparison), CNPG answer
    against warehouse answer.
  * The dashboard card and sparklines, which are warehouse-only readers
    (`MtrWarehouse.dashboard_summary/2`, `destination_sparkline/5`): their
    rollup routing against their raw fallback over the same data, which is the
    contract `RollupFreshness` enforces -- a stale view must cost the rollup,
    never change the answer. The CNPG half of the card is the dashboard's own
    SQL in `DashboardLive.Data.Mtr`; `MtrWarehouse` mirrors it clause by
    clause, and the raw fallback here executes that mirror against the live
    warehouse.

  Not compared: `MtrWarehouse.hop_latency_points/4` (its CNPG counterpart is
  an Ash read of `MtrHop` that needs the application database, not a query
  seam) and the pending/bulk job listings (Ash reads of `AgentCommand`, not
  telemetry readers).

  Runs only where both endpoints are configured: the SrqlParity workflow
  dispatch in buildbuddy.yaml names this target with the same environment the
  Rust harness gets. The env contract is that harness's own: the CNPG side is
  `SRQL_PARITY_CNPG_ADMIN_URL` (a role that may CREATE/DROP DATABASE) with
  `SRQL_PARITY_CNPG_CA_PEM` / `SRQL_PARITY_CNPG_SERVER_NAME` for TLS, and the
  StarRocks side is `SRQL_PARITY_STARROCKS_HOST/_PORT/_USER/_PASSWORD/
  _DATABASE` naming the fixed `srql_parity_*` warehouse database. A missing
  variable fails the test rather than skipping it: a parity check that
  silently skips protects nothing.

  All data here is synthetic: documentation-range addresses, private-use
  ASNs, invented agents, targets and devices, and timestamps derived from the
  run's own anchor. Nothing is captured from a deployment.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse

  # Workspace-relative: ex_unit_test mirrors the workspace layout, so this
  # is where the `//elixir/serviceradar_core:schema_template_baseline_sql`
  # data input lands in runfiles.
  @baseline_runfile "elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql"

  # Columns the committed baseline cannot carry because their migrations are
  # newer than the baseline cut; each names the migration it restates, as the
  # Rust harness's POST_BASELINE_COLUMNS does.
  @post_baseline_columns [
    {"mtr_hops", "target_ip", "text", "20260923120000_add_mtr_hop_target_attribution"},
    {"mtr_hops", "device_id", "text", "20260923120000_add_mtr_hop_target_attribution"},
    {"mtr_traces", "probed_hops", "integer", "20260924120000_add_mtr_trace_depth_fields"},
    {"mtr_traces", "last_responding_hop", "integer", "20260924120000_add_mtr_trace_depth_fields"},
    {"mtr_traces", "tcp_port", "integer", "20260924120000_add_mtr_trace_depth_fields"},
    {"mtr_hops", "unreachable_code", "integer", "20260924120000_add_mtr_trace_depth_fields"},
    {"mtr_traces", "tcp_handshake_ttl", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_handshake_attempts", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_syn_sent", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_synack_received", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_rst_received", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_syn_unanswered", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_syn_drop_pct", "double precision", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_syn_retransmits", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_answered_after_retx", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_ack_mismatch", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_synack_duplicates", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_handshake_rtt_min_us", "bigint", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_handshake_rtt_avg_us", "bigint", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_handshake_rtt_max_us", "bigint", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_traces", "tcp_server_response_us", "bigint", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_hops", "reply_time_exceeded", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_hops", "reply_unreachable", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_hops", "reply_synack", "integer", "20260924130000_add_mtr_tcp_handshake_fields"},
    {"mtr_hops", "reply_rst", "integer", "20260924130000_add_mtr_tcp_handshake_fields"}
  ]

  @mtr_views ["mtr_hops_hourly", "mtr_destination_hourly"]

  # Once per run: databases up, both sides seeded identically, both readers
  # one seam away.
  setup_all do
    sr_env = starrocks_env!()
    cnpg_env = cnpg_env!()

    prev_database = System.get_env("SERVICERADAR_STARROCKS_DATABASE")
    System.put_env("SERVICERADAR_STARROCKS_DATABASE", sr_env.database)

    prev_starrocks = Application.get_env(:serviceradar_core, StarRocks, [])
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev_starrocks, :enabled, true))

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev_starrocks)
      restore_env("SERVICERADAR_STARROCKS_DATABASE", prev_database)
    end)

    starrocks = start_starrocks!(sr_env)
    apply_starrocks_schema!(starrocks, sr_env.database)
    empty_starrocks!(starrocks, sr_env.database)

    run_database = "srql_parity_mtr_readers_#{System.system_time(:second)}"

    admin = start_postgrex!(cnpg_env, "postgres")
    Postgrex.query!(admin, "CREATE DATABASE #{run_database}", [])

    on_exit(fn ->
      try do
        Postgrex.query!(
          admin,
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
          [run_database]
        )
      rescue
        _ -> :ok
      end

      try do
        Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{run_database} WITH (FORCE)", [])
      rescue
        _ -> :ok
      end

      case Postgrex.query(admin, "SELECT 1 FROM pg_database WHERE datname = $1", [run_database]) do
        {:ok, %{rows: []}} -> :ok
        {:ok, %{rows: _}} -> flunk("scratch database #{run_database} was not deleted")
        {:error, _} -> :ok
      end
    end)

    cnpg = start_postgrex!(cnpg_env, run_database)
    apply_cnpg_schema!(cnpg)

    anchor = anchor()
    {traces, hops} = fixture(anchor)

    seed_cnpg!(cnpg, traces, hops)
    seed_starrocks!(starrocks, sr_env.database, traces, hops)
    refresh_starrocks_views!(starrocks, sr_env.database)

    on_exit(fn ->
      empty_starrocks!(starrocks, sr_env.database)
    end)

    cnpg_query = fn sql, params ->
      case Postgrex.query(cnpg, sql, params) do
        {:ok, %Postgrex.Result{} = result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end

    starrocks_query = fn sql -> MySQL.query(sql, conn: starrocks, timeout: 60_000) end

    %{
      anchor: anchor,
      traces: traces,
      hops: hops,
      starrocks: starrocks,
      database: sr_env.database,
      cnpg_query: cnpg_query,
      starrocks_query: starrocks_query
    }
  end

  # ---------------------------------------------------------------------------
  # The MtrData readers, CNPG against warehouse
  # ---------------------------------------------------------------------------

  test "the trace list agrees", ctx do
    for opts <- [
          [limit: 25],
          [limit: 40, target_filter: "parity"],
          [limit: 40, agent_filter: "agent-parity-02"],
          [limit: 40, device_ip: "198.51.100.10"]
        ] do
      cnpg = cnpg(fn -> MtrData.list_traces(opts ++ [cnpg_query: ctx.cnpg_query]) end)

      warehouse =
        warehouse(fn -> MtrData.list_traces(opts ++ [starrocks_query: ctx.starrocks_query]) end)

      assert_lists_equal(cnpg, warehouse, {:list_traces, opts})
    end
  end

  test "the paginated trace list agrees", ctx do
    for opts <- [
          [page: 1, limit: 20],
          [page: 2, limit: 20],
          [page: 1, limit: 20, srql_query: "target:parity-b"],
          [page: 1, limit: 20, sort: "target:asc"]
        ] do
      assert {:ok, cnpg} =
               cnpg(fn -> MtrData.list_traces_paginated(opts ++ [cnpg_query: ctx.cnpg_query]) end)

      assert {:ok, warehouse} =
               warehouse(fn ->
                 MtrData.list_traces_paginated(opts ++ [starrocks_query: ctx.starrocks_query])
               end)

      assert_maps_equal(cnpg, warehouse, {:list_traces_paginated, opts})
    end
  end

  test "the trace coverage agrees", ctx do
    for opts <- [[], [target_filter: "parity-b"], [device_ip: "198.51.100.10"]] do
      assert {:ok, cnpg} =
               cnpg(fn -> MtrData.trace_coverage(opts ++ [cnpg_query: ctx.cnpg_query]) end)

      assert {:ok, warehouse} =
               warehouse(fn ->
                 MtrData.trace_coverage(opts ++ [starrocks_query: ctx.starrocks_query])
               end)

      assert_maps_equal(cnpg, warehouse, {:trace_coverage, opts})
    end
  end

  test "the trace detail agrees", ctx do
    trace = Enum.find(ctx.traces, & &1.target_reached)

    cnpg =
      cnpg(fn ->
        MtrData.get_trace_detail(%{}, trace.id, cnpg_query: ctx.cnpg_query, time: trace.time)
      end)

    warehouse =
      warehouse(fn ->
        MtrData.get_trace_detail(%{}, trace.id,
          starrocks_query: ctx.starrocks_query,
          time: trace.time
        )
      end)

    assert {:ok, cnpg_trace, cnpg_hops} = cnpg
    assert {:ok, wh_trace, wh_hops} = warehouse
    assert_maps_equal(cnpg_trace, wh_trace, "trace row")
    assert_lists_equal(cnpg_hops, wh_hops, "trace hops")

    unreached = Enum.find(ctx.traces, &(!&1.target_reached))

    assert {:ok, cnpg_trace, cnpg_hops} =
             cnpg(fn ->
               MtrData.get_trace_detail(%{}, unreached.id, cnpg_query: ctx.cnpg_query)
             end)

    assert {:ok, wh_trace, wh_hops} =
             warehouse(fn ->
               MtrData.get_trace_detail(%{}, unreached.id, starrocks_query: ctx.starrocks_query)
             end)

    assert_maps_equal(cnpg_trace, wh_trace, "unreached trace row")
    assert_lists_equal(cnpg_hops, wh_hops, "unreached trace hops")
  end

  test "the Compare windows agree", ctx do
    anchor = ctx.anchor

    opts = [
      window_a: [start: shift(anchor, 1, :hour), end: shift(anchor, 4, :hour)],
      window_b: [start: shift(anchor, 5, :hour), end: shift(anchor, 8, :hour)],
      bucket_count: 12,
      signature_limit: 5
    ]

    assert {:ok, cnpg} =
             cnpg(fn -> MtrData.compare_windows(opts ++ [cnpg_query: ctx.cnpg_query]) end)

    assert {:ok, warehouse} =
             warehouse(fn ->
               MtrData.compare_windows(opts ++ [starrocks_query: ctx.starrocks_query])
             end)

    assert_maps_equal(cnpg, warehouse, "compare windows")
  end

  # `MtrData` dispatches on the global warehouse flag, not on which query seam
  # is present, so each side runs with the flag set for its backend. The
  # flag is restored afterwards; the module is async:false and its target runs
  # only this file.
  defp cnpg(fun), do: with_backend(false, fun)

  defp warehouse(fun), do: with_backend(true, fun)

  defp with_backend(enabled?, fun) do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, enabled?))

    try do
      fun.()
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  # ---------------------------------------------------------------------------
  # The dashboard card and sparklines: rollup against raw fallback
  # ---------------------------------------------------------------------------

  @tag timeout: 180_000
  test "late terminal hops refresh and scan only their event day across midnight", ctx do
    conn = ctx.starrocks
    database = ctx.database
    trace_template = hd(ctx.traces)
    hop_template = Enum.find(ctx.hops, &(&1.trace_id == trace_template.id))

    # These are event times, not load times. All three days exist before the
    # first day's missing hops arrive, after the newer days have been refreshed.
    traces =
      for {seconds, n} <- [{86_399, 1}, {86_401, 2}, {172_801, 3}] do
        time = DateTime.shift(ctx.anchor, second: seconds)

        %{
          trace_template
          | id: uuid(0x21, n),
            time: time,
            created_at: time,
            target_reached: n != 3
        }
      end

    make_hop = fn trace, n, sent, received, avg_us ->
      %{
        hop_template
        | id: uuid(0x22, n),
          trace_id: trace.id,
          time: trace.time,
          created_at: trace.time,
          hop_number: trace.total_hops,
          sent: sent,
          received: received,
          avg_us: avg_us
      }
    end

    [before_midnight, after_midnight, unreached] = traces
    initial_hops = [make_hop.(after_midnight, 4, 10, 10, 1_000), make_hop.(unreached, 5, 10, 9, 9_000)]
    lower = ctx.anchor |> DateTime.shift(hour: 23) |> DateTime.to_naive() |> NaiveDateTime.to_string()

    # Disable the schedule only in this disposable fixture. Otherwise a
    # scheduled refresh can consume the change before the measured manual run.
    sr!(MySQL.query("ALTER MATERIALIZED VIEW #{database}.mtr_destination_hourly REFRESH MANUAL", conn: conn))

    try do
      seed_starrocks!(conn, database, traces, initial_hops)
      refresh_starrocks_views!(conn, database)

      late_hops = [
        make_hop.(before_midnight, 1, 100, 100, 60_000),
        make_hop.(before_midnight, 2, 20, 18, 9_000),
        %{make_hop.(before_midnight, 3, 500, 0, 0) | hop_number: 1}
      ]

      seed_starrocks!(conn, database, [], late_hops)

      assert {:ok, %{rows: [[query_id]]}} =
               MySQL.query("REFRESH MATERIALIZED VIEW #{database}.mtr_destination_hourly WITH SYNC MODE",
                 conn: conn,
                 timeout: 120_000
               )

      assert {:ok, %{rows: [["SUCCESS", encoded]]}} =
               MySQL.query(
                 "SELECT STATE, EXTRA_MESSAGE FROM information_schema.task_runs WHERE QUERY_ID = #{quote_sr(query_id)}",
                 conn: conn
               )

      metadata = Jason.decode!(encoded)
      day = Calendar.strftime(before_midnight.time, "%Y%m%d")
      next_day = before_midnight.time |> DateTime.shift(day: 1) |> Calendar.strftime("%Y%m%d")
      partition = "p#{day}"

      assert metadata["mvPartitionsToRefresh"] == ["p#{day}_#{next_day}"]

      for key <- ["refBasePartitionsToRefreshMap", "basePartitionsToRefreshMap"] do
        assert metadata[key] == %{"mtr_traces" => [partition], "mtr_hops" => [partition]}
      end

      # This is the engine's generated refresh plan, not a grep of SQL source.
      assert metadata["planBuilderMessage"] == %{"mtr_traces" => partition, "mtr_hops" => partition}

      assert {:ok, %{rows: rows}} =
               MySQL.query(
                 """
                 SELECT path_count, endpoint_sample_count, loss_sample_count,
                   latency_sample_count, sent_total, received_total, avg_us_weighted,
                   latency_weight, degraded_count
                 FROM #{database}.mtr_destination_hourly
                 WHERE bucket >= #{quote_sr(lower)} ORDER BY bucket
                 """,
                 conn: conn
               )

      assert rows == [
               [1, 1, 1, 1, 20, 18, 162_000.0, 18, 1],
               [1, 1, 1, 1, 10, 10, 10_000.0, 10, 0],
               [1, 0, 0, 0, nil, nil, nil, nil, 1]
             ]

      cutoff = DateTime.shift(ctx.anchor, hour: 23)

      assert {:ok, %{rows: raw}} =
               MtrWarehouse.dashboard_summary(cutoff, starrocks_query: ctx.starrocks_query, query: stale_marks())

      assert {:ok, %{rows: rollup}} =
               MtrWarehouse.dashboard_summary(cutoff, starrocks_query: ctx.starrocks_query, query: fresh_marks())

      assert_lists_equal(raw, rollup, "late terminal hops across midnight")
    after
      ids = Enum.map_join(traces, ",", &quote_sr(&1.id))
      sr!(MySQL.query("DELETE FROM #{database}.mtr_hops WHERE trace_id IN (#{ids})", conn: conn))
      sr!(MySQL.query("DELETE FROM #{database}.mtr_traces WHERE id IN (#{ids})", conn: conn))
      refresh_starrocks_views!(conn, database)

      sr!(
        MySQL.query("ALTER MATERIALIZED VIEW #{database}.mtr_destination_hourly REFRESH ASYNC EVERY (INTERVAL 30 SECOND)",
          conn: conn
        )
      )
    end
  end

  test "the dashboard card's rollup read equals its raw fallback", ctx do
    cutoff = shift(ctx.anchor, 2, :hour)

    raw =
      MtrWarehouse.dashboard_summary(cutoff,
        starrocks_query: ctx.starrocks_query,
        query: stale_marks()
      )

    rollup =
      MtrWarehouse.dashboard_summary(cutoff,
        starrocks_query: ctx.starrocks_query,
        query: fresh_marks()
      )

    assert {:ok, %{rows: [raw_row]}} = raw
    assert {:ok, %{rows: [rollup_row]}} = rollup
    assert_lists_equal([raw_row], [rollup_row], "dashboard summary")
  end

  test "the sparklines' rollup reads equal their raw fallbacks", ctx do
    cutoff = shift(ctx.anchor, 1, :hour)

    for {bucket, metric} <- [
          {3_600, :loss_pct},
          {3_600, :latency_ms},
          {7_200, :loss_pct},
          {7_200, :latency_ms},
          {900, :loss_pct}
        ] do
      label = "sparkline #{bucket}s #{metric}"
      now = shift(ctx.anchor, 10, :hour)

      raw =
        MtrWarehouse.destination_sparkline(cutoff, bucket, metric, 96,
          starrocks_query: ctx.starrocks_query,
          query: stale_marks(),
          now: now
        )

      rollup =
        MtrWarehouse.destination_sparkline(cutoff, bucket, metric, 96,
          starrocks_query: ctx.starrocks_query,
          query: fresh_marks(),
          now: now
        )

      assert {:ok, %{rows: raw_rows}} = raw
      assert {:ok, %{rows: rollup_rows}} = rollup
      assert_lists_equal(raw_rows, rollup_rows, label)
    end
  end

  # ---------------------------------------------------------------------------
  # Environment and connections
  # ---------------------------------------------------------------------------

  defp starrocks_env! do
    %{
      host: required_env!("SRQL_PARITY_STARROCKS_HOST"),
      port: String.to_integer(required_env!("SRQL_PARITY_STARROCKS_PORT")),
      user: required_env!("SRQL_PARITY_STARROCKS_USER"),
      password: System.fetch_env!("SRQL_PARITY_STARROCKS_PASSWORD"),
      database: required_env!("SRQL_PARITY_STARROCKS_DATABASE")
    }
  end

  defp cnpg_env! do
    url = URI.parse(required_env!("SRQL_PARITY_CNPG_ADMIN_URL"))
    [user, pass] = String.split(url.userinfo, ":")

    %{
      host: url.host,
      port: url.port || 5432,
      username: URI.decode_www_form(user),
      password: URI.decode_www_form(pass),
      server_name: System.get_env("SRQL_PARITY_CNPG_SERVER_NAME"),
      ca_pem: System.get_env("SRQL_PARITY_CNPG_CA_PEM")
    }
  end

  defp required_env!(name) do
    case System.fetch_env(name) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> flunk("#{name} is not set; this test runs only in the SrqlParity workflow dispatch")
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp start_starrocks!(env) do
    # `MySQL.query/2` resolves its connection with `Process.whereis/1`,
    # which only accepts the registered pool atom the product uses -- an
    # anonymous MyXQL pid never resolves. Register this disposable test
    # connection under a fixed test-only name and return the name so every
    # existing `conn:` seam keeps working with no product client change.
    name = MtrReaderParityStarRocks
    if pid = Process.whereis(name), do: GenServer.stop(pid)

    {:ok, _conn} =
      MyXQL.start_link(
        [hostname: env.host,
         port: env.port,
         username: env.user,
         password: env.password,
         database: env.database,
         ssl: false,
         prepare: :unnamed,
         cache_size: 0,
         pool_size: 1,
         timeout: 60_000,
         connect_timeout: 10_000] ++ [name: name]
      )

    name
  end

  defp start_postgrex!(env, database) do
    ssl =
      if env.ca_pem do
        # OTP `ssl` needs certificate DER binaries in `cacerts`; the raw
        # `:public_key.pem_decode/1` tuples must be unwrapped first. Keep
        # `verify_peer` with hostname verification (SNI).
        cacerts =
          for {:Certificate, der, _} <- :public_key.pem_decode(env.ca_pem), do: der

        [
          verify: :verify_peer,
          cacerts: cacerts,
          depth: 3,
          server_name_indication: env.server_name && String.to_charlist(env.server_name)
        ]
      else
        false
      end

    {:ok, conn} =
      Postgrex.start_link(
        hostname: env.host,
        port: env.port,
        username: env.username,
        password: env.password,
        database: database,
        ssl: ssl,
        pool_size: 2,
        timeout: 60_000,
        connect_timeout: 10_000
      )

    conn
  end

  # ---------------------------------------------------------------------------
  # Schema application
  # ---------------------------------------------------------------------------

  # The StarRocks half applies the shipped migrations through the product's
  # own splitter and retargeter (`Schema`), skipping the CREATE DATABASE the
  # fixed database's user has no privilege for and ADD COLUMNs that already
  # ran -- the same guards the Rust harness states in `schema.rs`.
  defp apply_starrocks_schema!(conn, database) do
    for migration <- Schema.migrations() do
      for statement <- migration.statements do
        statement = Schema.retarget(statement, database, 1)

        if !(String.upcase(statement) =~ ~r/^CREATE DATABASE/) do
          starrocks_exec!(conn, statement, database)
        end
      end
    end
  end

  defp starrocks_exec!(conn, statement, database) do
    case Schema.add_column(statement) do
      {:ok, {table, column}} ->
        if !column_exists?(conn, database, table, column) do
          sr!(MySQL.query(statement, conn: conn, timeout: 60_000))
        end

      :error ->
        sr!(MySQL.query(statement, conn: conn, timeout: 60_000))
    end
  end

  defp column_exists?(conn, database, table, column) do
    sql = """
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = '#{database}' AND table_name = '#{table}' AND column_name = '#{column}'
    """

    case MySQL.query(sql, conn: conn, timeout: 60_000) do
      {:ok, %{rows: rows}} -> rows != []
      {:error, _reason} -> false
    end
  end

  # The CNPG half extracts the two MTR tables from the committed baseline (the
  # same source the Rust harness reads), creates them unqualified so the
  # readers' unqualified `FROM mtr_traces` resolves on the default search
  # path, and adds the post-baseline columns their migrations introduced.
  defp apply_cnpg_schema!(conn) do
    baseline = read_baseline!()

    for table <- ["mtr_hops", "mtr_traces"] do
      ddl = baseline |> baseline_table(table) |> String.replace("platform.", "")
      pg!(Postgrex.query(conn, ddl, []))
    end

    for {table, column, type, migration} <- @post_baseline_columns do
      pg!(
        Postgrex.query(conn, "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS #{column} #{type}", []),
        migration
      )
    end
  end

  defp read_baseline! do
    case baseline_path() do
      {:ok, path} -> File.read!(path)
      :error -> flunk("baseline not found: #{@baseline_runfile}")
    end
  end

  # The baseline SQL under Bazel (RUNFILES_DIR, or the manifest beside the
  # test when only that is set), falling back to the checkout tree this file
  # lives in (`__DIR__` is `elixir/web-ng/test/integration/starrocks`, five
  # levels below the root).
  defp baseline_path do
    runfile =
      cond do
        dir = System.get_env("RUNFILES_DIR") -> Path.join(dir, @baseline_runfile)
        manifest = System.get_env("RUNFILES_MANIFEST_FILE") -> manifest_lookup(manifest)
        true -> nil
      end

    checkout =
      Path.expand(Path.join(List.duplicate("..", 5) ++ [@baseline_runfile]), __DIR__)

    [runfile, checkout]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp manifest_lookup(manifest) do
    prefix = @baseline_runfile <> " "

    manifest
    |> File.stream!()
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix) do
        line |> String.slice(String.length(prefix)..-1//1) |> String.trim()
      end
    end)
  end

  defp baseline_table(baseline, table) do
    marker = "CREATE TABLE platform.#{table} ("

    start =
      case :binary.match(baseline, marker) do
        {pos, _} -> pos
        :nomatch -> flunk("baseline has no #{table}")
      end

    body_start = start + byte_size(marker) - 1
    rest = :binary.part(baseline, body_start, byte_size(baseline) - body_start)

    stop =
      case :binary.match(rest, "\n);") do
        {offset, _} -> body_start + offset
        :nomatch -> flunk("baseline #{table} has no terminator")
      end

    :binary.part(baseline, start, stop + 2 - start) <> ";"
  end

  # ---------------------------------------------------------------------------
  # Seeding: one synthetic fixture, two renderings
  # ---------------------------------------------------------------------------

  defp anchor do
    now = DateTime.utc_now()
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    DateTime.shift(midnight, day: -2)
  end

  defp shift(%DateTime{} = time, n, unit), do: DateTime.add(time, n, unit)

  # Synthetic from nothing: documentation-range addresses, private-use ASNs,
  # invented agents and targets. `sent` cycles so loss as a ratio of probe
  # totals differs from any mean of per-hop percentages; `received` drives
  # avg_us so a weighted mean differs from a plain AVG; one hop never replies
  # (NULL address and latency); one target never reaches; one reaches one
  # trace in three.
  @target_specs [
    {"parity-a.example.net", "198.51.100.10", "sr:parity-dev-a", :always},
    {"parity-b.example.net", "198.51.100.20", "sr:parity-dev-b", :third},
    {"198.51.100.30", "198.51.100.30", "sr:parity-dev-c", :never}
  ]

  @agents [{"agent-parity-01", "gw-parity-01"}, {"agent-parity-02", "gw-parity-02"}]

  # {addr, asn, received_delta, base_us}; received_delta is added to sent, and
  # a NULL base_us is a hop that never replied.
  @paths %{
    "198.51.100.10" => [
      {"192.0.2.1", nil, 0, 400},
      {"192.0.2.2", 64_512, -1, 2_000},
      {nil, nil, :never, nil},
      {"198.51.100.10", 64_520, -1, 9_000}
    ],
    "198.51.100.20" => [
      {"203.0.113.5", nil, 0, 600},
      {"203.0.113.6", 64_530, -2, 3_000},
      {"198.51.100.20", 64_531, -1, 8_000}
    ],
    "198.51.100.30" => [
      {"203.0.113.7", 0, 0, 500},
      {"203.0.113.8", nil, :never, nil}
    ]
  }

  defp fixture(anchor) do
    # Agent two only probes the first target.
    for_result =
      for slot <- 0..26,
          {target, target_ip, device, reach} <- @target_specs,
          {agent, gateway} <- @agents,
          reduce: {[], []} do
        {traces, hops} ->
          if agent == "agent-parity-02" and target != "parity-a.example.net" do
            {traces, hops}
          else
            n = length(traces) + 1
            time = DateTime.shift(anchor, second: slot * 1_200 + n * 7)
            sent = Enum.at([5, 10, 20], Integer.mod(slot + n, 3))

            reached? =
              case reach do
                :always -> true
                :third -> Integer.mod(slot, 3) == 0
                :never -> false
              end

            path = @paths[target_ip]
            total_hops = length(path)
            trace_id = uuid(0x11, n)

            trace = %{
              id: trace_id,
              time: time,
              agent_id: agent,
              gateway_id: gateway,
              check_id: "parity-chk-#{Integer.mod(n, 3)}",
              check_name: "parity check #{Integer.mod(n, 3)}",
              device_id: device,
              target: target,
              target_ip: target_ip,
              target_reached: reached?,
              total_hops: total_hops,
              probed_hops: if(reached?, do: total_hops, else: total_hops - 1),
              last_responding_hop: if(reached?, do: total_hops, else: 1),
              protocol: "icmp",
              tcp_port: nil,
              ip_version: 4,
              packet_size: 60,
              partition: nil,
              error: if(reached?, do: nil, else: "no reply"),
              created_at: time
            }

            trace_hops =
              path
              |> Enum.with_index(1)
              |> Enum.map(fn {{addr, asn, received_delta, base_us}, hop_number} ->
                received =
                  case received_delta do
                    :never -> 0
                    0 -> sent
                    delta -> max(sent + delta, 0)
                  end

                avg_us =
                  if is_nil(base_us) or received == 0,
                    do: nil,
                    else: base_us + 25 * (sent - received)

                %{
                  id: uuid(0x12, n * 16 + hop_number),
                  time: time,
                  trace_id: trace_id,
                  target_ip: target_ip,
                  device_id: device,
                  hop_number: hop_number,
                  addr: addr,
                  hostname: if(addr, do: "hop-#{hop_number}.parity.example.net"),
                  asn: asn,
                  asn_org: if(asn, do: "PARITY AS #{asn}"),
                  sent: sent,
                  received: received,
                  loss_pct: if(sent > 0, do: 100.0 * (sent - received) / sent, else: 0.0),
                  avg_us: avg_us,
                  min_us: if(avg_us, do: avg_us - 50),
                  max_us: if(avg_us, do: avg_us + 80),
                  jitter_us: if(avg_us, do: 10 + hop_number),
                  created_at: time
                }
              end)

            {[trace | traces], trace_hops ++ hops}
          end
      end

    then(for_result, fn {traces, hops} -> {Enum.reverse(traces), Enum.reverse(hops)} end)
  end

  # A deterministic synthetic UUID; the prefix keeps trace and hop ids in
  # disjoint ranges, and no real trace id can appear here.
  defp uuid(prefix, n) do
    low = (prefix * 4_294_967_296 + n) |> Integer.to_string(16) |> String.pad_leading(12, "0")
    Ecto.UUID.cast!("00000000-0000-4000-8000-#{low}")
  end

  defp seed_cnpg!(conn, traces, hops) do
    for batch <- Enum.chunk_every(traces, 50) do
      {sql, params} = cnpg_trace_insert(batch)
      pg!(Postgrex.query(conn, sql, params))
    end

    for batch <- Enum.chunk_every(hops, 50) do
      {sql, params} = cnpg_hop_insert(batch)
      pg!(Postgrex.query(conn, sql, params))
    end
  end

  defp cnpg_trace_insert(batch) do
    columns =
      ~w(id time agent_id gateway_id check_id check_name device_id target target_ip target_reached
        total_hops probed_hops last_responding_hop protocol tcp_port ip_version packet_size partition
        error created_at)

    {placeholders, params} =
      Enum.map_reduce(batch, [], fn trace, params ->
        values = [
          trace.id,
          trace.time,
          trace.agent_id,
          trace.gateway_id,
          trace.check_id,
          trace.check_name,
          trace.device_id,
          trace.target,
          trace.target_ip,
          trace.target_reached,
          trace.total_hops,
          trace.probed_hops,
          trace.last_responding_hop,
          trace.protocol,
          trace.tcp_port,
          trace.ip_version,
          trace.packet_size,
          trace.partition,
          trace.error,
          trace.created_at
        ]

        index = length(params)
        row = Enum.map(1..length(values), &"$#{index + &1}")
        {row, params ++ values}
      end)

    sql =
      "INSERT INTO mtr_traces (#{Enum.join(columns, ", ")}) VALUES " <>
        Enum.map_join(placeholders, ", ", &"(#{Enum.join(&1, ", ")})")

    {sql, params}
  end

  defp cnpg_hop_insert(batch) do
    columns =
      ~w(id time trace_id target_ip device_id hop_number addr hostname asn asn_org sent received
        loss_pct avg_us min_us max_us jitter_us created_at)

    {placeholders, params} =
      Enum.map_reduce(batch, [], fn hop, params ->
        values = [
          hop.id,
          hop.time,
          hop.trace_id,
          hop.target_ip,
          hop.device_id,
          hop.hop_number,
          hop.addr,
          hop.hostname,
          hop.asn,
          hop.asn_org,
          hop.sent,
          hop.received,
          hop.loss_pct,
          hop.avg_us,
          hop.min_us,
          hop.max_us,
          hop.jitter_us,
          hop.created_at
        ]

        index = length(params)
        row = Enum.map(1..length(values), &"$#{index + &1}")
        {row, params ++ values}
      end)

    sql =
      "INSERT INTO mtr_hops (#{Enum.join(columns, ", ")}) VALUES " <>
        Enum.map_join(placeholders, ", ", &"(#{Enum.join(&1, ", ")})")

    {sql, params}
  end

  defp seed_starrocks!(conn, database, traces, hops) do
    for batch <- Enum.chunk_every(traces, 50) do
      sr!(MySQL.query(starrocks_trace_insert(database, batch), conn: conn, timeout: 60_000))
    end

    for batch <- Enum.chunk_every(hops, 50) do
      sr!(MySQL.query(starrocks_hop_insert(database, batch), conn: conn, timeout: 60_000))
    end
  end

  defp starrocks_trace_insert(database, batch) do
    columns =
      ~w(id `time` agent_id gateway_id check_id check_name device_id target target_ip target_reached
        total_hops probed_hops last_responding_hop protocol tcp_port ip_version packet_size
        `partition` error created_at)a

    rows =
      Enum.map_join(batch, ",\n", fn trace ->
        [
          quote_sr(trace.id),
          quote_sr(NaiveDateTime.to_string(DateTime.to_naive(trace.time))),
          quote_sr(trace.agent_id),
          quote_sr(trace.gateway_id),
          quote_sr(trace.check_id),
          quote_sr(trace.check_name),
          quote_sr(trace.device_id),
          quote_sr(trace.target),
          quote_sr(trace.target_ip),
          trace.target_reached,
          trace.total_hops,
          trace.probed_hops,
          trace.last_responding_hop,
          quote_sr(trace.protocol),
          "NULL",
          trace.ip_version,
          trace.packet_size,
          "NULL",
          quote_sr(trace.error),
          quote_sr(NaiveDateTime.to_string(DateTime.to_naive(trace.created_at)))
        ]
        |> Enum.join(", ")
        |> then(&"(#{&1})")
      end)

    "INSERT INTO #{database}.mtr_traces (#{Enum.join(columns, ", ")}) VALUES\n#{rows}"
  end

  defp starrocks_hop_insert(database, batch) do
    columns =
      ~w(id `time` trace_id target_ip device_id hop_number addr hostname asn asn_org sent received
        loss_pct avg_us min_us max_us jitter_us created_at)a

    rows =
      Enum.map_join(batch, ",\n", fn hop ->
        [
          quote_sr(hop.id),
          quote_sr(NaiveDateTime.to_string(DateTime.to_naive(hop.time))),
          quote_sr(hop.trace_id),
          quote_sr(hop.target_ip),
          quote_sr(hop.device_id),
          hop.hop_number,
          quote_sr(hop.addr),
          quote_sr(hop.hostname),
          if(is_nil(hop.asn), do: "NULL", else: hop.asn),
          quote_sr(hop.asn_org),
          hop.sent,
          hop.received,
          Float.round(hop.loss_pct, 6),
          if(is_nil(hop.avg_us), do: "NULL", else: hop.avg_us),
          if(is_nil(hop.min_us), do: "NULL", else: hop.min_us),
          if(is_nil(hop.max_us), do: "NULL", else: hop.max_us),
          if(is_nil(hop.jitter_us), do: "NULL", else: hop.jitter_us),
          quote_sr(NaiveDateTime.to_string(DateTime.to_naive(hop.created_at)))
        ]
        |> Enum.join(", ")
        |> then(&"(#{&1})")
      end)

    "INSERT INTO #{database}.mtr_hops (#{Enum.join(columns, ", ")}) VALUES\n#{rows}"
  end

  defp quote_sr(nil), do: "NULL"

  defp quote_sr(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "\\'") <> "'"
  end

  defp refresh_starrocks_views!(conn, database) do
    for view <- @mtr_views do
      sr!(
        MySQL.query("REFRESH MATERIALIZED VIEW #{database}.#{view} WITH SYNC MODE",
          conn: conn,
          timeout: 120_000
        )
      )
    end
  end

  defp empty_starrocks!(conn, database) do
    for table <- ["mtr_hops", "mtr_traces"] do
      sr!(MySQL.query("DELETE FROM #{database}.#{table} WHERE 1=1", conn: conn, timeout: 120_000))
    end

    for view <- @mtr_views do
      sr!(
        MySQL.query("REFRESH MATERIALIZED VIEW #{database}.#{view} WITH SYNC MODE",
          conn: conn,
          timeout: 120_000
        )
      )
    end
  end

  # Freshness runners for the rollup-vs-raw comparisons: the marks answer the
  # two probes RollupFreshness issues, equal for fresh and hours apart for
  # stale.
  defp fresh_marks, do: marks(~N[2026-01-02 12:00:00], ~N[2026-01-02 12:00:00])

  defp stale_marks, do: marks(~N[2026-01-02 12:00:00], ~N[2026-01-02 02:00:00])

  defp marks(raw_max, mv_max) do
    fn
      "SELECT MAX(`time`) FROM " <> _ -> {:ok, %{rows: [[raw_max]]}}
      "SELECT IS_ACTIVE," <> _ -> {:ok, %{rows: [["true", "SUCCESS", 15]]}}
      "SELECT MAX(`bucket`) FROM " <> _ -> {:ok, %{rows: [[mv_max]]}}
      _other -> {:error, :unexpected_probe}
    end
  end

  # ---------------------------------------------------------------------------
  # Comparison: same answers, floats within a rounding of each other
  # ---------------------------------------------------------------------------

  defp assert_lists_equal(left, right, label) when is_list(left) and is_list(right) do
    if !lists_equal?(left, right) do
      flunk("""
      #{inspect(label)}: CNPG and the warehouse disagree.

      left (#{length(left)} rows):
      #{inspect(left, limit: 25, pretty: true)}

      right (#{length(right)} rows):
      #{inspect(right, limit: 25, pretty: true)}
      """)
    end

    :ok
  end

  defp assert_lists_equal(left, right, label) do
    flunk("#{inspect(label)}: unexpected shapes #{inspect(left)} vs #{inspect(right)}")
  end

  defp assert_maps_equal(left, right, label) when is_map(left) and is_map(right) do
    if !maps_equal?(left, right) do
      flunk("""
      #{inspect(label)}: CNPG and the warehouse disagree.

      cnpg:
      #{inspect(left, limit: 25, pretty: true)}

      warehouse:
      #{inspect(right, limit: 25, pretty: true)}
      """)
    end

    :ok
  end

  defp assert_maps_equal(left, right, label) do
    flunk("#{inspect(label)}: unexpected shapes #{inspect(left)} vs #{inspect(right)}")
  end

  defp lists_equal?(left, right) do
    length(left) == length(right) and
      left |> Enum.zip(right) |> Enum.all?(fn {l, r} -> values_equal?(l, r) end)
  end

  defp maps_equal?(left, right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {k, v} -> values_equal?(v, Map.get(right, k)) end)
  end

  defp values_equal?(%DateTime{} = l, %DateTime{} = r), do: DateTime.compare(l, r) == :eq

  defp values_equal?(%NaiveDateTime{} = l, %NaiveDateTime{} = r), do: NaiveDateTime.compare(l, r) == :eq

  # Postgrex returns timestamptz as DateTime and MyXQL returns DATETIME as
  # NaiveDateTime; compare on the naive instant, both are UTC.
  defp values_equal?(%DateTime{} = l, %NaiveDateTime{} = r), do: values_equal?(DateTime.to_naive(l), r)

  defp values_equal?(%NaiveDateTime{} = l, %DateTime{} = r), do: values_equal?(l, DateTime.to_naive(r))

  # A NUMERIC aggregate arrives as Decimal from Postgrex; compare by value,
  # with the same rounding tolerance against a float. These sit above the
  # map clause: a struct is a map, and the generic clause would compare
  # `__struct__` atoms and always disagree.
  defp values_equal?(%Decimal{} = l, %Decimal{} = r), do: Decimal.equal?(l, r)
  defp values_equal?(%Decimal{} = l, r) when is_float(r), do: values_equal?(Decimal.to_float(l), r)
  defp values_equal?(%Decimal{} = l, r) when is_integer(r), do: Decimal.equal?(l, Decimal.new(r))
  defp values_equal?(l, %Decimal{} = r) when is_number(l), do: values_equal?(r, l)

  defp values_equal?(l, r) when is_map(l) and is_map(r), do: maps_equal?(l, r)
  defp values_equal?(l, r) when is_list(l) and is_list(r), do: lists_equal?(l, r)

  defp values_equal?(l, r) when is_float(l) and is_float(r) do
    # CNPG computes in NUMERIC and the warehouse in DOUBLE, and summation
    # order differs; anything larger than a rounding is a real difference.
    abs(l - r) <= 1.0e-6 * max(max(abs(l), abs(r)), 1.0)
  end

  defp values_equal?(l, r) when is_integer(l) and is_integer(r), do: l == r

  # Counts arrive as integers from one driver and floats from the other when
  # the value passed through a ratio; the float tolerance above still holds
  # them to agreement.
  defp values_equal?(l, r) when is_integer(l) and is_float(r), do: values_equal?(l * 1.0, r)
  defp values_equal?(l, r) when is_float(l) and is_integer(r), do: values_equal?(l, r * 1.0)

  defp values_equal?(l, r) when is_binary(l) and is_binary(r), do: l == r
  defp values_equal?(l, r) when is_boolean(l) and is_boolean(r), do: l == r
  defp values_equal?(nil, nil), do: true

  defp values_equal?(%DateTime{} = _l, _r), do: false
  defp values_equal?(_l, _r), do: false

  # ---------------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------------

  defp pg!({:ok, _result}), do: :ok
  defp pg!({:error, reason}), do: raise("CNPG statement failed: #{inspect(reason)}")
  defp pg!({:ok, _result}, _migration), do: :ok
  defp pg!({:error, reason}, migration), do: raise("#{migration} failed: #{inspect(reason)}")

  defp sr!({:ok, _result}), do: :ok
  defp sr!({:error, reason}), do: raise("StarRocks statement failed: #{inspect(reason)}")
end
