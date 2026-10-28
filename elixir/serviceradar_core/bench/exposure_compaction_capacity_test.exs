defmodule ServiceRadar.ExposureCompactionCapacityTest do
  @moduledoc """
  Decision 26 capacity oracle. SQL constructs synthetic starting state; only the
  production Oban worker and Stream Load path perform the measured maintenance.
  """
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.EventWriter.ExposureTerminalCompactionWorker
  alias ServiceRadar.Repo

  @oban __MODULE__.Oban
  @queue :exposure_capacity
  @tables ~w(exposure_facts exposure_cve_dim exposure_package_dim exposure_retired_ordinals exposure_transitions_log)
  @deadline_ms 900_000
  @cve_base 20_260_000_000

  @tag sandbox: :unboxed
  @tag timeout: 2_400_000
  test "terminal compaction finishes the selected workload within fifteen minutes" do
    profile = profile!()
    config = warehouse_config!()
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    previous_database = System.get_env("SERVICERADAR_STARROCKS_DATABASE")

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, previous)

      if previous_database,
        do: System.put_env("SERVICERADAR_STARROCKS_DATABASE", previous_database),
        else: System.delete_env("SERVICERADAR_STARROCKS_DATABASE")
    end)

    Application.put_env(:serviceradar_core, StarRocks, config)
    System.put_env("SERVICERADAR_STARROCKS_DATABASE", config[:database])
    refute Process.whereis(MySQL), "capacity run requires its own warehouse pool"
    start_supervised!({MyXQL, MySQL.connection_opts(config)})
    if !Process.whereis(LoadSupervisor), do: start_supervised!(LoadSupervisor)

    # Refuse reuse before registering destructive cleanup. The external
    # coordinator additionally checks that this schema has never been used.
    for table <- @tables, do: assert([[0]] == query!("SELECT count(*) FROM #{table}"))

    # Oban's real stager considers every queue. This target runs alone on a fresh
    # canonical fixture clone; it must never stage another test's retained work.
    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM platform.oban_jobs WHERE state IN ('scheduled', 'retryable')"
             ).rows

    errors =
      try do
        run_capacity!(profile)
        []
      catch
        kind, reason -> [{kind, reason, __STACKTRACE__}]
      end

    cleanup_errors =
      Enum.flat_map(@tables, fn table ->
        try do
          query!("TRUNCATE TABLE #{table}")
          assert [[0]] == query!("SELECT count(*) FROM #{table}")
          []
        catch
          kind, reason -> [{kind, reason, __STACKTRACE__}]
        end
      end)

    if errors ++ cleanup_errors != [],
      do: raise(ExUnit.MultiError, errors: errors ++ cleanup_errors)
  end

  defp profile! do
    case System.fetch_env!("EXPOSURE_CAPACITY_PROFILE") do
      "smoke" -> %{name: "smoke", hosts: 200, active: 500_000, terminal: 10_000}
      "fleet" -> %{name: "fleet", hosts: 20_000, active: 50_000_000, terminal: 1_000_000}
      _ -> flunk("EXPOSURE_CAPACITY_PROFILE must be smoke or fleet")
    end
  end

  defp warehouse_config! do
    assert System.fetch_env!("EXPOSURE_LIVE_WAREHOUSE") == "1"
    database = System.fetch_env!("EXPOSURE_LIVE_DATABASE")
    assert Regex.match?(~r/^exposure_reconcile_[a-f0-9]{32}$/, database)

    [
      enabled: true,
      database: database,
      fe_http: System.fetch_env!("EXPOSURE_LIVE_FE_HTTP"),
      fe_mysql_host: System.fetch_env!("EXPOSURE_LIVE_MYSQL_HOST"),
      fe_mysql_port: String.to_integer(System.fetch_env!("EXPOSURE_LIVE_MYSQL_PORT")),
      user: System.fetch_env!("EXPOSURE_LIVE_USER"),
      password: System.fetch_env!("EXPOSURE_LIVE_PASSWORD")
    ]
  end

  defp run_capacity!(profile) do
    cutoff =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 86_400) |> NaiveDateTime.truncate(:second)

    dates = %{
      cutoff: NaiveDateTime.to_iso8601(cutoff),
      old: cutoff |> NaiveDateTime.add(-86_400) |> NaiveDateTime.to_string(),
      recent: cutoff |> NaiveDateTime.add(86_400) |> NaiveDateTime.to_string()
    }

    seed_started = now_ms()
    seed!(profile, dates)
    verify!(profile, dates, false)
    seed_ms = now_ms() - seed_started

    # Keep the production Basic engine, database peer, default one-second
    # stager and maintenance concurrency. A separate queue prevents execution
    # of unrelated application jobs. No inline/drain/manual perform shortcut.
    start_supervised!(
      {Oban,
       name: @oban,
       repo: Repo,
       prefix: "platform",
       engine: Oban.Engines.Basic,
       testing: :disabled,
       notifier: Oban.Notifiers.PG,
       peer: Oban.Peers.Database,
       plugins: false,
       queues: [{@queue, 2}]}
    )

    started = now_ms()

    job =
      Oban.insert!(
        @oban,
        ExposureTerminalCompactionWorker.new(%{"cutoff" => dates.cutoff}, queue: @queue)
      )

    try do
      refute job.conflict?, "capacity job must be newly inserted"
      result = await_job(job.id, started + @deadline_ms)
      elapsed = now_ms() - started
      stored = Repo.get!(Oban.Job, job.id)

      # Quiesce the writer before the independent table oracle and teardown,
      # including on timeout. A completed job alone is never a passing result.
      :ok = Oban.cancel_job(@oban, job.id)
      stop_supervised!(@oban)

      [[remaining]] =
        query!(
          "SELECT count(*) FROM exposure_facts WHERE pkg_ord BETWEEN 2501 AND 2550 AND payload_compacted = false"
        )

      IO.puts(
        "EXPOSURE_COMPACTION_CAPACITY " <>
          Jason.encode!(%{
            profile: profile.name,
            active_facts: profile.active,
            eligible_terminal_facts: profile.terminal,
            recent_terminal_controls: profile.hosts,
            fixture_ms: seed_ms,
            worker_ms: elapsed,
            result: result,
            remaining: remaining,
            snoozes: stored.meta["snoozed"] || 0
          })
      )

      assert result == :completed, "capacity worker failed or exceeded fifteen minutes"
      assert remaining == 0
      assert stored.errors == []

      assert (stored.meta["snoozed"] || 0) >= 1,
             "smoke and fleet must exercise actual scheduler resumption"

      verify!(profile, dates, true)
      elapsed_with_verification = now_ms() - started
      assert elapsed_with_verification <= @deadline_ms

      IO.puts(
        "EXPOSURE_COMPACTION_CAPACITY_VERIFIED " <>
          Jason.encode!(%{
            profile: profile.name,
            elapsed_ms: elapsed_with_verification,
            violations: 0
          })
      )
    after
      if Oban.whereis(@oban) do
        Oban.cancel_job(@oban, job.id)
        stop_supervised!(@oban)
      end

      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
      refute Repo.exists?(from(j in Oban.Job, where: j.id == ^job.id))
    end
  end

  defp await_job(id, deadline) do
    job = Repo.get!(Oban.Job, id)

    cond do
      now_ms() > deadline ->
        :deadline_exceeded

      job.state == "completed" ->
        :completed

      job.errors != [] or job.state in ["cancelled", "discarded"] ->
        :failed

      true ->
        Process.sleep(250)
        await_job(id, deadline)
    end
  end

  defp seed!(profile, dates) do
    for {kind, count} <- [
          active: profile.active,
          terminal: profile.terminal,
          recent: profile.hosts
        ],
        first <- 0..(count - 1)//1_000_000 do
      last = min(first + 999_999, count - 1)
      {device, cve, package, sequence, state, resolved} = seed_columns(kind, profile, dates)

      query!("""
      INSERT INTO exposure_facts
        (device_ord, cve_ord, pkg_ord, pkgver_ord, state, source_scope,
         severity_rank, cvss_score, kev, exploit_available, fix_available,
         first_exposed_at, resolved_at, updated_at, transition_seq,
         transition_xid, snapshot_generation, device_lifecycle_seq, payload_compacted)
      SELECT #{device}, #{cve}, #{package}, 10000 + (#{package}), #{state}, 'package',
             4, 7.5, true, true, false, '2000-01-01 00:00:00', #{resolved},
             '2000-01-02 00:00:00', #{sequence}, 11, 7, 13, false
      FROM (SELECT generate_series AS n FROM TABLE(generate_series(#{first}, #{last}))) synthetic
      """)
    end
  end

  defp seed_columns(:active, _profile, _dates) do
    {"1 + n DIV 2500", "#{@cve_base} + 1 + n % 50000", "1 + n % 2500", "100 + n", "1", "NULL"}
  end

  defp seed_columns(:terminal, profile, dates) do
    {"1 + n DIV 50", "#{@cve_base} + 1 + n % 50000", "2501 + n % 50",
     "#{100 + profile.active} + n", "IF(n % 2 = 0, 0, 2)", "'#{dates.old}'"}
  end

  defp seed_columns(:recent, profile, dates) do
    {"1 + n", "#{@cve_base + 1}", "3000", "#{100 + profile.active + profile.terminal} + n", "0",
     "'#{dates.recent}'"}
  end

  defp verify!(profile, dates, compacted?) do
    assert [[total]] = query!("SELECT count(*) FROM exposure_facts")
    assert total == profile.active + profile.terminal + profile.hosts

    for {kind, expected} <- [
          active: profile.active,
          terminal: profile.terminal,
          recent: profile.hosts
        ] do
      {scope, identity} = expected_identity(kind, profile, dates)
      payload = if kind == :terminal and compacted?, do: cleared_payload(), else: full_payload()

      assert [[count, 0]] =
               query!("""
               SELECT count(*), sum(CASE WHEN
                 device_ord BETWEEN 1 AND #{profile.hosts}
                 AND #{identity}
                 AND transition_xid = 11 AND snapshot_generation = 7 AND device_lifecycle_seq = 13
                 AND updated_at = '2000-01-02 00:00:00'
                 AND #{payload}
               THEN 0 ELSE 1 END)
               FROM exposure_facts WHERE #{scope}
               """),
             "#{kind} row count or stored content violated the synthetic oracle"

      assert count == expected
    end
  end

  # Reconstruct each row's index from its primary key rather than trusting a
  # checksum generated by the worker or a sample of rows from the result.
  defp expected_identity(:active, _profile, _dates) do
    n = "((device_ord - 1) * 2500 + pkg_ord - 1)"

    {"pkg_ord BETWEEN 1 AND 2500",
     "cve_ord = #{@cve_base} + 1 + #{n} % 50000 AND transition_seq = 100 + #{n} AND state = 1 AND resolved_at IS NULL"}
  end

  defp expected_identity(:terminal, profile, dates) do
    n = "((device_ord - 1) * 50 + pkg_ord - 2501)"

    {"pkg_ord BETWEEN 2501 AND 2550",
     "cve_ord = #{@cve_base} + 1 + #{n} % 50000 AND transition_seq = #{100 + profile.active} + #{n} AND state = IF(#{n} % 2 = 0, 0, 2) AND resolved_at = '#{dates.old}'"}
  end

  defp expected_identity(:recent, profile, dates) do
    {"pkg_ord = 3000",
     "cve_ord = #{@cve_base + 1} AND transition_seq = #{99 + profile.active + profile.terminal} + device_ord AND state = 0 AND resolved_at = '#{dates.recent}'"}
  end

  defp full_payload do
    """
    pkgver_ord = 10000 + pkg_ord AND source_scope = 'package' AND severity_rank = 4
    AND cvss_score = 7.5 AND kev = true AND exploit_available = true AND fix_available = false
    AND first_exposed_at = '2000-01-01 00:00:00' AND payload_compacted = false
    """
  end

  defp cleared_payload do
    """
    pkgver_ord = 0 AND source_scope IS NULL AND severity_rank IS NULL AND cvss_score IS NULL
    AND kev IS NULL AND exploit_available IS NULL AND fix_available IS NULL
    AND first_exposed_at IS NULL AND payload_compacted = true
    """
  end

  defp query!(sql) do
    case MySQL.query(sql, timeout: 120_000) do
      {:ok, %{rows: rows}} -> rows
      {:error, _reason} -> flunk("capacity warehouse query failed")
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
