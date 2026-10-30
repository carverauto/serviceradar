defmodule ServiceRadar.ExposureReconciliationCapacityTest do
  @moduledoc """
  Decision 26 daily reconciliation capacity, through the real fleet enumerator
  and two-worker maintenance queue. Synthetic starting state is loaded outside
  the timer; this does not measure source publication or snapshot rebuilding.
  """
  use ServiceRadar.DataCase, async: false

  alias Oban.Notifiers.PG
  alias Oban.Peers.Database
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.ExposureAudit.Prototype
  alias ServiceRadar.ExposureAudit.State
  alias ServiceRadar.Inventory.ExposureReadiness
  alias ServiceRadar.Inventory.ExposureReconciliationWorker
  alias ServiceRadar.Observability.ObanFailureEventReporter
  alias ServiceRadar.Repo

  @warehouse ~w(exposure_facts exposure_cve_dim exposure_package_dim exposure_retired_ordinals exposure_transitions_log)
  @source ~w(endpoint_vulnerability_assessments exposure_reconciliation_checks exposure_snapshot_generations
             exposure_delivery_batches exposure_fact_watermarks exposure_transition_outbox exposure_dimension_outbox
             exposure_device_refreshes exposure_dimension_state exposure_package_version_ordinals
             exposure_package_ordinals exposure_advisory_ordinals device_fleet_ordinals endpoint_packages ocsf_devices)
  @deadline_ms 900_000
  @cve_base 20_260_000_000
  @worker "ServiceRadar.Inventory.ExposureReconciliationWorker"

  @tag sandbox: :unboxed
  @tag timeout: 3_600_000
  test "daily fleet reconciliation verifies the selected workload within fifteen minutes" do
    hosts = profile!()
    audit? = System.get_env("EXPOSURE_AUDIT_PROTOTYPE") == "1"

    if audit?,
      do: assert(hosts == 200, "audit prototype is restricted to the approved small profile")

    configure_warehouse!()

    # This manual target owns a fresh canonical fixture clone and a never-used
    # warehouse schema. Refuse reuse before registering any destructive cleanup.
    for table <- @source, do: assert([[0]] == pg!("SELECT count(*) FROM platform.#{table}"))
    for table <- @warehouse, do: assert([[0]] == warehouse!("SELECT count(*) FROM #{table}"))

    assert [[0]] =
             pg!(
               "SELECT count(*) FROM platform.oban_jobs WHERE state IN ('executing', 'scheduled', 'retryable')"
             )

    assert Oban.config().testing == :manual
    bootstrap_jobs = pg!("SELECT id, queue FROM platform.oban_jobs")
    # Fresh core startup admits bootstrap jobs even with testing=:manual. Park
    # them in an unserved queue, retain their rows, and restore the queues later.
    pg!("UPDATE platform.oban_jobs SET queue = 'capacity_bootstrap'")
    assert :ok = Supervisor.terminate_child(ServiceRadar.Supervisor, Oban)
    # Failure notifications target general event tables, outside this exposure
    # schema. Persisted Oban errors below remain the benchmark's failure oracle.
    assert :ok = Supervisor.terminate_child(ServiceRadar.Supervisor, ObanFailureEventReporter)

    errors =
      capture_errors(fn ->
        if audit? do
          State.install!()
          Process.put(:exposure_audit_installed, true)
        end

        seeded = now_ms()
        seed!(hosts)
        verify_fixture!(hosts)
        fixture_ms = now_ms() - seeded

        [[source_bytes]] =
          pg!("SELECT pg_total_relation_size('platform.endpoint_vulnerability_assessments')")

        IO.puts(
          "EXPOSURE_RECONCILIATION_FIXTURE " <>
            Jason.encode!(%{hosts: hosts, fixture_ms: fixture_ms, assessment_bytes: source_bytes})
        )

        run_capacity!(hosts, fixture_ms)
        if audit?, do: run_audit!(hosts)
        reject_equal_count_corruption!()
      end)

    shutdown_errors = capture_errors(&stop_queue!/0)
    cleanup_errors = if shutdown_errors == [], do: capture_errors(&cleanup!/0), else: []

    restore_errors =
      capture_errors(fn ->
        for [id, queue] <- bootstrap_jobs,
            do: Repo.query!("UPDATE platform.oban_jobs SET queue = $2 WHERE id = $1", [id, queue])

        assert {:ok, _} = Supervisor.restart_child(ServiceRadar.Supervisor, Oban)

        assert {:ok, _} =
                 Supervisor.restart_child(ServiceRadar.Supervisor, ObanFailureEventReporter)
      end)

    audit_cleanup_errors =
      if Process.delete(:exposure_audit_installed),
        do: capture_errors(&State.uninstall!/0),
        else: []

    all_errors =
      errors ++ shutdown_errors ++ cleanup_errors ++ restore_errors ++ audit_cleanup_errors

    if all_errors != [], do: raise(ExUnit.MultiError, errors: all_errors)
  end

  defp run_audit!(hosts) do
    start_supervised!(
      {Oban,
       repo: Repo,
       prefix: "platform",
       testing: :manual,
       notifier: PG,
       queues: false,
       plugins: false,
       peer: false}
    )

    measurement =
      capture_errors(fn ->
        Prototype.measure!(hosts, &verify_fixture!/1, "first")
      end)

    diagnostics = capture_errors(&Prototype.diagnose!/0)
    controls = capture_errors(&ServiceRadar.ExposureAudit.Controls.verify!/0)
    stop_queue!()

    if measurement ++ diagnostics ++ controls != [],
      do: raise(ExUnit.MultiError, errors: measurement ++ diagnostics ++ controls)
  end

  defp profile! do
    case System.fetch_env!("EXPOSURE_CAPACITY_PROFILE") do
      "smoke" -> 200
      "fleet" -> 20_000
      _ -> flunk("EXPOSURE_CAPACITY_PROFILE must be smoke or fleet")
    end
  end

  defp configure_warehouse! do
    assert System.fetch_env!("EXPOSURE_LIVE_WAREHOUSE") == "1"
    database = System.fetch_env!("EXPOSURE_LIVE_DATABASE")
    assert Regex.match?(~r/^exposure_reconcile_[a-f0-9]{32}$/, database)
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    previous_database = System.get_env("SERVICERADAR_STARROCKS_DATABASE")

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, previous)

      if previous_database,
        do: System.put_env("SERVICERADAR_STARROCKS_DATABASE", previous_database),
        else: System.delete_env("SERVICERADAR_STARROCKS_DATABASE")
    end)

    config = [
      enabled: true,
      database: database,
      fe_http: System.fetch_env!("EXPOSURE_LIVE_FE_HTTP"),
      fe_mysql_host: System.fetch_env!("EXPOSURE_LIVE_MYSQL_HOST"),
      fe_mysql_port: String.to_integer(System.fetch_env!("EXPOSURE_LIVE_MYSQL_PORT")),
      user: System.fetch_env!("EXPOSURE_LIVE_USER"),
      password: System.fetch_env!("EXPOSURE_LIVE_PASSWORD")
    ]

    Application.put_env(:serviceradar_core, StarRocks, config)
    System.put_env("SERVICERADAR_STARROCKS_DATABASE", database)
    refute Process.whereis(MySQL), "capacity run requires its own warehouse pool"
    start_supervised!({MyXQL, MySQL.connection_opts(config)})
  end

  defp run_capacity!(hosts, fixture_ms) do
    # Child jobs use the production default Oban instance and maintenance queue.
    # Replacing the idle test instance avoids rerouting production code or
    # manually performing/draining the measured work.
    start_supervised!(
      {Oban,
       repo: Repo,
       prefix: "platform",
       testing: :disabled,
       engine: Oban.Engines.Basic,
       notifier: PG,
       peer: Database,
       plugins: [],
       queues: [maintenance: 2]}
    )

    assert {Database, _} = Oban.config().peer
    started = now_ms()
    job = Oban.insert!(ExposureReconciliationWorker.new(%{}))
    refute job.conflict?
    result = await_fleet(hosts, started + @deadline_ms)
    elapsed = now_ms() - started

    if result != :completed do
      for [worker, errors] <-
            pg!(
              "SELECT worker, errors FROM platform.oban_jobs WHERE queue = 'maintenance' AND errors <> '{}' ORDER BY id LIMIT 2"
            ) do
        IO.puts(
          "EXPOSURE_RECONCILIATION_JOB_ERROR " <>
            Jason.encode!(%{
              worker: worker,
              errors: Enum.map(errors, &String.slice(&1["error"] || "unknown", 0, 2000))
            })
        )
      end
    end

    stop_queue!()

    [[matched]] =
      pg!(
        "SELECT count(*) FROM platform.exposure_reconciliation_checks WHERE device_ord > 0 AND status = 'matched'"
      )

    [[snoozes]] =
      pg!(
        "SELECT COALESCE((meta->>'snoozed')::int, 0) FROM platform.oban_jobs WHERE id = #{job.id}"
      )

    IO.puts(
      "EXPOSURE_RECONCILIATION_CAPACITY " <>
        Jason.encode!(%{
          hosts: hosts,
          active_facts: hosts * 2500,
          terminal_facts: hosts * 51,
          fixture_ms: fixture_ms,
          worker_ms: elapsed,
          result: result,
          matched_devices: matched,
          remaining_devices: hosts - matched,
          enumerator_snoozes: snoozes
        })
    )

    assert result == :completed, "fleet reconciliation failed or exceeded fifteen minutes"
    assert matched == hosts
    assert snoozes > 0

    assert [[0]] =
             pg!("""
             SELECT count(*) FROM platform.exposure_reconciliation_checks
             WHERE device_ord > 0 AND (
               status <> 'matched' OR (control->'source'->>'count')::bigint IS DISTINCT FROM 2500
               OR control->'source' IS DISTINCT FROM control->'warehouse'
               OR (control->>'started_at')::timestamp < (SELECT updated_at FROM platform.exposure_snapshot_generations)
               OR checked_at < (SELECT (control->>'started_at')::timestamp
                 FROM platform.exposure_reconciliation_checks WHERE device_ord = 0))
             """)

    assert {:ok, %{ready: true}} = ExposureReadiness.status()
    verify_fixture!(hosts)
    verified_ms = now_ms() - started
    assert verified_ms <= @deadline_ms

    IO.puts(
      "EXPOSURE_RECONCILIATION_CAPACITY_VERIFIED " <>
        Jason.encode!(%{hosts: hosts, elapsed_ms: verified_ms, violations: 0})
    )
  end

  defp await_fleet(hosts, deadline) do
    [[completed, failed, unexpected]] =
      pg!("""
      SELECT count(*) FILTER (WHERE worker = '#{@worker}' AND state = 'completed'),
        count(*) FILTER (WHERE errors <> '{}' OR state IN ('cancelled', 'discarded')),
      count(*) FILTER (WHERE worker <> '#{@worker}') FROM platform.oban_jobs WHERE queue = 'maintenance'
      """)

    cond do
      now_ms() > deadline ->
        :deadline_exceeded

      failed > 0 or unexpected > 0 ->
        :failed

      completed == hosts + 1 ->
        :completed

      true ->
        Process.sleep(500)
        await_fleet(hosts, deadline)
    end
  end

  defp stop_queue! do
    if Oban.whereis(Oban) do
      if Oban.config().testing == :disabled do
        :ok = Oban.pause_queue(queue: :maintenance)

        ids =
          pg!(
            "SELECT id FROM platform.oban_jobs WHERE queue = 'maintenance' AND state NOT IN ('completed', 'cancelled', 'discarded')"
          )

        for [id] <- ids, do: :ok = Oban.cancel_job(id)
      end

      stop_supervised!(Oban)
    end
  end

  defp reject_equal_count_corruption! do
    # Outside the timed run: a same-count corruption must become a durable
    # mismatch and block readiness, not be certified by count alone. The idle
    # manual instance records the replacement job without launching a snapshot.
    start_supervised!(
      {Oban,
       repo: Repo,
       prefix: "platform",
       testing: :manual,
       notifier: PG,
       queues: false,
       plugins: false,
       peer: false}
    )

    warehouse!("UPDATE exposure_facts SET severity_rank = 1 WHERE device_ord = 1 AND pkg_ord = 1")

    assert {:snooze, 30} =
             ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => 1}})

    assert [["mismatch"]] =
             pg!(
               "SELECT status FROM platform.exposure_reconciliation_checks WHERE device_ord = 1"
             )

    assert {:ok, %{ready: false}} = ExposureReadiness.status(1)
    IO.puts("EXPOSURE_RECONCILIATION_NEGATIVE_CONTROL same_count_corruption_rejected")
    stop_supervised!(Oban)
  end

  defp seed!(hosts) do
    # Fixture construction alone bypasses source publication triggers. User
    # triggers are restored in the same transaction; constraints remain active.
    assert {:ok, _} =
             Repo.transaction(
               fn ->
                 without_source_triggers(fn ->
                   pg!(
                     "INSERT INTO platform.ocsf_devices(uid) SELECT 'sr:capacity-' || n FROM generate_series(1, #{hosts}) n"
                   )

                   pg!(
                     "INSERT INTO platform.device_fleet_ordinals(uid, ordinal) SELECT 'sr:capacity-' || n, n FROM generate_series(1, #{hosts}) n"
                   )

                   pg!("""
                   INSERT INTO platform.endpoint_packages(id, coordinate_key, package_manager, name, version)
                   SELECT lpad(to_hex(n), 32, '0')::uuid, 'capacity-package-' || n, 'deb', 'capacity-package-' || n, '1.0'
                   FROM generate_series(1, 2551) n
                   """)

                   pg!(
                     "INSERT INTO platform.exposure_package_ordinals(package_identity_key, ordinal) SELECT 'capacity-package-' || n, n FROM generate_series(1, 2551) n"
                   )

                   pg!(
                     "INSERT INTO platform.exposure_package_version_ordinals(package_identity_key, installed_version, ordinal) SELECT 'capacity-package-' || n, '1.0', n FROM generate_series(1, 2551) n"
                   )

                   seed_dimensions!()
                 end)
               end,
               timeout: 120_000
             )

    for first <- 1..hosts//20 do
      assert {:ok, _} =
               Repo.transaction(
                 fn ->
                   without_source_triggers(fn ->
                     seed_assessments!(first, min(first + 19, hosts))
                   end)
                 end,
                 timeout: 120_000
               )
    end

    for table <-
          ~w(endpoint_vulnerability_assessments device_fleet_ordinals exposure_dimension_state exposure_package_version_ordinals),
        do: pg!("ANALYZE platform.#{table}")

    warehouse!("""
    INSERT INTO exposure_cve_dim (cve_ord, cve_id, epss_score, transition_seq, updated_at)
    SELECT #{@cve_base} + n, concat('CVE-2026-', IF(n < 10000, lpad(cast(n AS STRING), 4, '0'), cast(n AS STRING))),
      NULL, n, '2000-01-02 00:00:00' FROM (SELECT generate_series AS n FROM TABLE(generate_series(1, 50000))) s
    """)

    warehouse!("""
    INSERT INTO exposure_package_dim (pkgver_ord, pkg_ord, package_identity_key, package_name, installed_version, transition_seq, updated_at)
    SELECT n, n, concat('capacity-package-', n), concat('capacity-package-', n), '1.0', 50000+n, '2000-01-02 00:00:00'
    FROM (SELECT generate_series AS n FROM TABLE(generate_series(1, 2551))) s
    """)

    for first <- 0..(hosts * 2551 - 1)//1_000_000 do
      last = min(first + 999_999, hosts * 2551 - 1)

      warehouse!("""
      INSERT INTO exposure_facts (device_ord, cve_ord, pkg_ord, pkgver_ord, state, source_scope,
        severity_rank, cvss_score, kev, exploit_available, fix_available, first_exposed_at,
        resolved_at, updated_at, transition_seq, transition_xid, snapshot_generation, device_lifecycle_seq, payload_compacted)
      SELECT 1+n DIV 2551, #{@cve_base}+1+((n DIV 2551)*2500+n%2551)%50000, 1+n%2551, 1+n%2551,
        IF(n%2551 < 2500, 1, 0), 'host', 4, 7.5, true, true, false, '2000-01-01 00:00:00',
        IF(n%2551 < 2500, NULL, '2000-01-02 00:00:00'), '2000-01-02 00:00:00',
        100000+n, 11, 1, 0, false
      FROM (SELECT generate_series AS n FROM TABLE(generate_series(#{first}, #{last}))) s
      """)
    end

    # A previously completed recovery is starting state, not a claim that this
    # benchmark measures snapshot publication. Comparisons must postdate it.
    pg!("""
    INSERT INTO platform.exposure_snapshot_generations(status, control, inserted_at, updated_at)
    VALUES ('complete', '{}', now() - interval '1 second', now() - interval '1 second')
    """)
  end

  defp seed_dimensions! do
    pg!("""
    INSERT INTO platform.exposure_dimension_state(kind, ordinal, content, payload, transition_seq)
    SELECT 'cve', #{@cve_base}+n, body,
      body || jsonb_build_object('schema_version', 1, 'dimension', 'cve', 'transition_seq', n,
        'updated_at', '2000-01-02T00:00:00'), n
    FROM generate_series(1, 50000) n CROSS JOIN LATERAL (
      SELECT jsonb_build_object('cve_ord', #{@cve_base}+n,
        'cve_id', 'CVE-2026-' || CASE WHEN n<10000 THEN lpad(n::text,4,'0') ELSE n::text END,
        'epss_score', NULL) AS body) s
    """)

    pg!("""
    INSERT INTO platform.exposure_dimension_state(kind, ordinal, content, payload, transition_seq)
    SELECT 'package', n, body,
      body || jsonb_build_object('schema_version', 1, 'dimension', 'package', 'transition_seq', 50000+n,
        'updated_at', '2000-01-02T00:00:00'), 50000+n
    FROM generate_series(1, 2551) n CROSS JOIN LATERAL (
      SELECT jsonb_build_object('pkgver_ord', n, 'pkg_ord', n, 'package_identity_key', 'capacity-package-' || n,
        'package_name', 'capacity-package-' || n, 'installed_version', '1.0') AS body) s
    """)
  end

  defp seed_assessments!(first, last) do
    pg!("""
    INSERT INTO platform.endpoint_vulnerability_assessments
      (id, device_uid, endpoint_package_ref, cve_id, status, assessment, disposition,
       applicability_reason, package_identity_key, package_name, installed_version, source_scope,
       severity, cvss_score, kev, exploit_available, first_seen_at, last_seen_at,
       last_transition_seq, exposed_at, resolved_at, last_exposure_publication)
    SELECT lpad(to_hex(n+1),32,'0')::uuid, 'sr:capacity-' || host,
      lpad(to_hex(pkg),32,'0')::uuid, cve, state, 'confirmed', 'affected', 'synthetic capacity fixture',
      'capacity-package-' || pkg, 'capacity-package-' || pkg, '1.0', 'host',
      'critical', 7.5, true, true, '2000-01-01', '2000-01-02', 100000+n, '2000-01-01',
      CASE WHEN pkg>2500 THEN timestamp '2000-01-02' ELSE NULL END,
      jsonb_build_object('schema_version',1, 'device_uid','sr:capacity-' || host,
        'package_identity_key','capacity-package-' || pkg, 'cve_id',cve, 'installed_version','1.0',
        'device_ord',host, 'cve_ord',#{@cve_base}+cve_number, 'pkg_ord',pkg, 'pkgver_ord',pkg,
        'transition_seq',100000+n, 'transition_xid',11, 'device_lifecycle_seq',0,
        'state',state, 'source_scope','host', 'severity','critical', 'cvss_score',7.5,
        'kev',true, 'exploit_available',true, 'fix_available',false,
        'first_exposed_at','2000-01-01T00:00:00',
        'resolved_at',CASE WHEN pkg>2500 THEN '2000-01-02T00:00:00' ELSE NULL END,
        'changed_at','2000-01-02T00:00:00')
    FROM generate_series(#{first},#{last}) host CROSS JOIN generate_series(1,2551) pkg
    CROSS JOIN LATERAL (SELECT (host-1)::bigint*2551+pkg-1 AS n,
      1+((host-1)*2500+pkg-1)%50000 AS cve_number,
      CASE WHEN pkg<=2500 THEN 'active' ELSE 'resolved' END AS state) s
    CROSS JOIN LATERAL (SELECT 'CVE-2026-' || CASE WHEN cve_number<10000
      THEN lpad(cve_number::text,4,'0') ELSE cve_number::text END AS cve) c
    """)
  end

  defp verify_fixture!(hosts) do
    assert [[total, active, devices]] =
             pg!("""
             SELECT count(*), count(*) FILTER (WHERE status='active'), count(DISTINCT device_uid)
             FROM platform.endpoint_vulnerability_assessments
             """)

    assert {total, active, devices} == {hosts * 2551, hosts * 2500, hosts}

    assert [[^total, ^active, ^hosts, 50_000, 0]] =
             warehouse!("""
             SELECT count(*), sum(IF(state=1,1,0)), count(DISTINCT device_ord), count(DISTINCT cve_ord),
               sum(IF(device_ord BETWEEN 1 AND #{hosts} AND pkg_ord BETWEEN 1 AND 2551
                 AND cve_ord=#{@cve_base}+1+((device_ord-1)*2500+pkg_ord-1)%50000
                 AND transition_seq=100000+(device_ord-1)*2551+pkg_ord-1
                 AND state=IF(pkg_ord<=2500,1,0) AND severity_rank=4 AND cvss_score=7.5
                 AND pkgver_ord=pkg_ord AND device_lifecycle_seq=0 AND kev=true
                 AND exploit_available=true AND fix_available=false AND source_scope='host',0,1))
             FROM exposure_facts
             """)
  end

  defp without_source_triggers(fun) do
    tables = ~w(ocsf_devices device_fleet_ordinals endpoint_vulnerability_assessments)
    for table <- tables, do: pg!("ALTER TABLE platform.#{table} DISABLE TRIGGER USER")
    result = fun.()
    for table <- tables, do: pg!("ALTER TABLE platform.#{table} ENABLE TRIGGER USER")
    result
  end

  defp cleanup! do
    # The initial emptiness guard establishes ownership. TRUNCATE avoids firing
    # deletion-publication triggers for fifty million synthetic source rows.
    # Receipts still reference assessments; uninstall drops that schema later.
    # PostgreSQL rejects a parent TRUNCATE while the foreign key exists, including
    # when the child is empty. Name both tables in this one statement.
    if Process.get(:exposure_audit_installed) do
      pg!(
        "TRUNCATE platform.exposure_audit_receipts, platform.endpoint_vulnerability_assessments"
      )

      assert [[0]] == pg!("SELECT count(*) FROM platform.exposure_audit_receipts")
    else
      pg!("TRUNCATE platform.endpoint_vulnerability_assessments")
    end
    pg!("DELETE FROM platform.oban_jobs WHERE queue = 'maintenance'")

    assert {:ok, _} =
             Repo.transaction(fn ->
               without_source_triggers(fn ->
                 for table <- tl(@source), do: pg!("DELETE FROM platform.#{table}")
               end)
             end)

    for table <- @source, do: assert([[0]] == pg!("SELECT count(*) FROM platform.#{table}"))
    assert [[0]] = pg!("SELECT count(*) FROM platform.oban_jobs WHERE queue = 'maintenance'")

    for table <- @warehouse do
      warehouse!("TRUNCATE TABLE #{table}")
      assert [[0]] == warehouse!("SELECT count(*) FROM #{table}")
    end
  end

  defp pg!(sql), do: Repo.query!(sql, [], timeout: 120_000).rows

  defp warehouse!(sql) do
    case MySQL.query(sql, timeout: 120_000) do
      {:ok, %{rows: rows}} -> rows
      {:error, _} -> flunk("capacity warehouse query failed")
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp capture_errors(fun) do
    fun.()
    []
  catch
    kind, reason -> [{kind, reason, __STACKTRACE__}]
  end
end
