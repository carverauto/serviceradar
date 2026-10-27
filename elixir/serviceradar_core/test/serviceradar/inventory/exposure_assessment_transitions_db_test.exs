defmodule ServiceRadar.Inventory.ExposureAssessmentTransitionsDbTest do
  @moduledoc """
  The transactional outbox contract of *Assessment Transitions Are Published On
  JetStream*, at the database boundary that owns it: the triggers on
  `endpoint_vulnerability_assessments`, whichever writer changes a row. The
  matcher lifecycle (enter, resolve on upgrade, unchanged rerun) is asserted in
  `EndpointVulnerabilityAssessmentMatcherTest`.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Snapshot
  alias ServiceRadar.EventWriter.ExposureSnapshotMaintenanceWorker
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: SnapshotWarehouse
  alias ServiceRadar.EventWriter.Processors.ExposureDimensions
  alias ServiceRadar.EventWriter.Processors.ExposureSnapshots
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.Inventory.ExposureDeviceRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRelay
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureReadiness
  alias ServiceRadar.Inventory.ExposureReconciliationWorker
  alias ServiceRadar.Inventory.ExposureSnapshotFinalizer
  alias ServiceRadar.Inventory.ExposureSnapshotRepairs
  alias ServiceRadar.Inventory.ExposureSnapshotState
  alias ServiceRadar.Inventory.ExposureSnapshotWorker
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ExposureBroker
  alias ServiceRadar.TestSupport.ExposureTransitionCleanup

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    {:ok, unique: unique, device_uid: "sr:exposure-transition-#{unique}"}
  end

  @tag sandbox: :unboxed
  @tag :tmp_dir
  @tag :live_warehouse
  @tag timeout: 600_000
  @tag skip: is_nil(System.get_env("EXPOSURE_LIVE_WAREHOUSE"))
  test "live warehouse reconciliation retains repairs through loss, upgrades and queued traffic",
       ctx do
    config = live_warehouse_config!()
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
    refute Process.whereis(MySQL), "live scenario requires its own MySQL pool"
    start_supervised!({MyXQL, MySQL.connection_opts(config)})
    if !Process.whereis(LoadSupervisor), do: start_supervised!(LoadSupervisor)

    tables =
      ~w(exposure_facts exposure_cve_dim exposure_package_dim exposure_retired_ordinals exposure_transitions_log)

    # The coordinator owns this unique schema. Never empty a reused database.
    for table <- tables do
      assert {:ok, %{rows: [[0]]}} = MySQL.query("SELECT count(*) FROM #{table}")
    end

    journal_ids =
      List.flatten(
        Repo.query!("SELECT operation_id FROM platform.exposure_delivery_batches").rows
      )

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.exposure_delivery_batches WHERE NOT (operation_id = ANY($1::uuid[]))",
        [
          journal_ids
        ]
      )
    end)

    errors =
      try do
        cve = "EXAMPLE-LIVE-RECONCILE"
        {scope, original, _dimensions} = reconciliation_source!(ctx, cve, false)
        args = %{"device_ord" => scope}

        ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
          {:ok, _} = Gnat.sub(conn, self(), "exposure.snapshots.>")
          first = live_snapshot!(conn, args)
          assert {:ok, %{ready: false}} = ExposureReadiness.status(scope)
          assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
          assert {:ok, %{ready: true, generation: ^first}} = ExposureReadiness.status(scope)

          assert {:ok, %{rows: [[1]]}} =
                   MySQL.query("SELECT count(*) FROM exposure_facts WHERE device_ord = #{scope}")

          # Real storage loss must admit replacement work before readiness returns.
          assert {:ok, _} = MySQL.query("DELETE FROM exposure_facts WHERE device_ord = #{scope}")

          assert {:ok, %{rows: [[0]]}} =
                   MySQL.query("SELECT count(*) FROM exposure_facts WHERE device_ord = #{scope}")

          assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
          assert {:ok, %{ready: false}} = ExposureReadiness.status(scope)

          assert Repo.exists?(
                   from(j in Oban.Job,
                     where:
                       j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                         j.state == "available" and
                         fragment("?->>'device_ord'", j.args) == ^to_string(scope)
                   )
                 )

          replacement = live_snapshot!(conn, args)
          assert replacement > first
          assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
          assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)

          # Current columns, not retained replay, are the comparison oracle.
          assert {:ok, _} =
                   Repo.transaction(fn ->
                     Repo.query!("""
                     ALTER TABLE platform.endpoint_vulnerability_assessments
                       DISABLE TRIGGER trg_exposure_assessment_sequence,
                       DISABLE TRIGGER trg_exposure_assessment_publish_update
                     """)

                     update_assessment!(ctx.device_uid, cve, kev: true, severity: "critical")

                     Repo.query!("""
                     ALTER TABLE platform.endpoint_vulnerability_assessments
                       ENABLE TRIGGER trg_exposure_assessment_sequence,
                       ENABLE TRIGGER trg_exposure_assessment_publish_update
                     """)
                   end)

          assert publication(ctx.device_uid, cve) == original
          assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
          repaired = publication(ctx.device_uid, cve)
          assert repaired["kev"] == true
          assert repaired["severity"] == "critical"
          assert repaired["transition_seq"] > original["transition_seq"]

          assert {:ok, %{ready: false, metrics: %{repair_pending: 1}}} =
                   ExposureReadiness.status(scope)

          live_snapshot!(conn, args)
          assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

          old_key = repaired["pkgver_ord"]

          assert {:ok, _} =
                   MySQL.query("DELETE FROM exposure_package_dim WHERE pkgver_ord = #{old_key}")

          assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

          [[%{"repairs" => [assigned]}]] =
            Repo.query!(
              "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
              [scope]
            ).rows

          assert assigned["kind"] == "package"
          assert assigned["key"] == old_key

          # PubAck without ingestion, then upgrade away from V1 before its repair settles.
          live_dimensions!(conn, false)
          update_assessment!(ctx.device_uid, cve, installed_version: "2.0.0")
          upgraded = publication(ctx.device_uid, cve)
          refute upgraded["pkgver_ord"] == old_key

          assert {:ok, current} =
                   DirectSession.run(fn reader ->
                     ExposureSnapshotWorker.source_page(reader, "dimensions", scope, nil)
                   end)

          refute Enum.any?(current, fn [key, _] -> key == ["package", old_key] end)
          assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

          assert {:ok, %{ready: false, metrics: %{repair_pending: 1}}} =
                   ExposureReadiness.status(scope)

          live_dimensions!(conn, true)
          assert {:ok, []} = ExposureSnapshotRepairs.verify([assigned])
          live_snapshot!(conn, args)
          assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
          assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)

          # A confirmed assigned CVE repair must not chase a newer queued EPSS update.
          ordinal = original["cve_ord"]

          [[before]] =
            Repo.query!(
              "SELECT payload FROM platform.exposure_dimension_state WHERE kind = 'cve' AND ordinal = $1",
              [ordinal]
            ).rows

          assert {:ok, {:ok, [target]}} =
                   Repo.transaction(fn ->
                     ExposureSnapshotRepairs.publish([
                       %{
                         "kind" => "cve",
                         "key" => ordinal,
                         "observed" => before["transition_seq"]
                       }
                     ])
                   end)

          live_dimensions!(conn, true)
          assert {:ok, []} = ExposureSnapshotRepairs.verify([target])
          content = before |> Map.take(["cve_ord", "cve_id"]) |> Map.put("epss_score", 0.25)

          [[newer]] =
            Repo.query!("SELECT platform.exposure_publish_dimension('cve',$1,$2,false)", [
              ordinal,
              content
            ]).rows

          assert newer > target["required"]

          assert {:ok, {:ok, [replayed]}} =
                   Repo.transaction(fn -> ExposureSnapshotRepairs.publish([target]) end)

          assert {:ok, []} = ExposureSnapshotRepairs.verify([replayed])

          assert [[1]] =
                   Repo.query!(
                     "SELECT 1 FROM platform.exposure_dimension_outbox WHERE kind = 'cve' AND ordinal = $1 AND transition_seq = $2",
                     [ordinal, newer]
                   ).rows

          live_global_readiness!(conn, ctx, scope, cve)
          live_union_paging!(conn, ctx)
          live_delivery_orders!(conn, ctx)

          Repo.query!(
            "UPDATE platform.exposure_reconciliation_checks SET checked_at = now() - interval '2 days' WHERE device_ord = $1",
            [scope]
          )

          assert {:ok, %{ready: false}} = ExposureReadiness.status(scope)
          Application.put_env(:serviceradar_core, StarRocks, Keyword.put(config, :enabled, false))
          assert {:error, :starrocks_required} = ExposureReadiness.status(scope)

          assert [["active"]] =
                   Repo.query!(
                     "SELECT status FROM platform.endpoint_vulnerability_assessments WHERE device_uid = $1",
                     [ctx.device_uid]
                   ).rows
        end)
      else
        _ -> []
      catch
        kind, reason -> [{kind, reason, __STACKTRACE__}]
      end

    cleanup_errors =
      Enum.flat_map(tables, fn table ->
        try do
          assert {:ok, _} = MySQL.query("TRUNCATE TABLE #{table}")
          live_empty_table!(table, System.monotonic_time(:millisecond) + 5_000)
          []
        catch
          kind, reason -> [{kind, reason, __STACKTRACE__}]
        end
      end)

    if errors ++ cleanup_errors != [] do
      raise ExUnit.MultiError, errors: errors ++ cleanup_errors
    end
  end

  defp live_warehouse_config! do
    assert System.fetch_env!("EXPOSURE_LIVE_WAREHOUSE") == "1"
    database = System.fetch_env!("EXPOSURE_LIVE_DATABASE")

    assert Regex.match?(~r/^exposure_reconcile_[a-f0-9]{32}$/, database),
           "live warehouse requires a uniquely owned exposure_reconcile_<32 hex> schema"

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

  defp live_snapshot!(conn, args) do
    publisher = Task.async(fn -> ExposureSnapshotWorker.perform(%Oban.Job{args: args}) end)

    try do
      generation = live_snapshot_messages!(conn)
      assert :ok = Task.await(publisher, 30_000)
      live_finalize!(generation, 20)
      generation
    after
      Task.shutdown(publisher, :brutal_kill)
    end
  end

  # Finalization scans one bounded page per invocation, including the final empty page.
  defp live_finalize!(generation, attempts) do
    assert attempts > 0, "live snapshot did not finish within its bounded scan budget"

    case ExposureSnapshotFinalizer.step(generation) do
      :ok ->
        assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(generation)

      {:error, :exposure_snapshot_finalization_pending} ->
        live_finalize!(generation, attempts - 1)

      {:error, :exposure_snapshot_repairs_pending} ->
        flunk(
          "live snapshot repairs pending: #{inspect(live_repair_diagnostics(generation), limit: :infinity)}"
        )

      other ->
        flunk("live snapshot finalization failed: #{inspect(other)}")
    end
  end

  # Failure-only evidence from this generation's synthetic facts, before cleanup.
  # Never print connection errors or configuration, and never hide the primary failure.
  defp live_repair_diagnostics(generation) do
    {:ok, state} = ExposureSnapshotState.get(generation)

    repairs =
      state["repairs"]
      |> Enum.take(5)
      |> Enum.map(fn repair ->
        [uid, package, cve] = repair["source"]
        key = repair["key"]
        {:ok, warehouse} = SnapshotWarehouse.read("fact", [key])

        source =
          Repo.query!(
            """
            SELECT kev, severity, last_exposure_publication
            FROM platform.endpoint_vulnerability_assessments
            WHERE device_uid = $1 AND package_identity_key = $2 AND cve_id = $3
            """,
            [uid, package, cve]
          ).rows

        retained =
          Enum.map(source, fn [kev, severity, payload] ->
            {:ok, [%{fact: fact}]} = ExposureTransitions.decode([%{data: Jason.encode!(payload)}])
            %{current_kev: kev, current_severity: severity, retained: fact}
          end)

        queued =
          Repo.query!(
            """
            SELECT transition_seq FROM platform.exposure_transition_outbox
            WHERE device_uid = $1 AND payload->>'cve_id' = $2
              AND payload->>'package_identity_key' = $3
            ORDER BY id LIMIT 20
            """,
            [uid, cve, package]
          ).rows

        %{
          repair: Map.take(repair, ~w(kind key observed required expected)),
          source: retained,
          warehouse: warehouse[key],
          queued_sequences: List.flatten(queued)
        }
      end)

    %{generation: generation, repair_count: length(state["repairs"]), repairs: repairs}
  rescue
    _ -> :repair_diagnostics_unavailable
  end

  defp live_global_readiness!(conn, ctx, scope, cve) do
    other_ctx = %{ctx | unique: ctx.unique + 1, device_uid: ctx.device_uid <> "-coverage"}
    {other, _, _} = reconciliation_source!(other_ctx, "EXAMPLE-LIVE-COVERAGE", false)

    [[saved]] =
      Repo.query!(
        "SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) FROM platform.exposure_reconciliation_checks c"
      ).rows

    [[job_floor]] = Repo.query!("SELECT COALESCE(max(id), 0) FROM oban_jobs").rows

    [[generation_floor]] =
      Repo.query!("SELECT COALESCE(max(id), 0) FROM platform.exposure_snapshot_generations").rows

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM oban_jobs WHERE id > $1 AND worker IN ('ServiceRadar.Inventory.ExposureSnapshotWorker', 'ServiceRadar.Inventory.ExposureReconciliationWorker')",
        [job_floor]
      )

      Repo.query!("DELETE FROM platform.exposure_snapshot_generations WHERE id > $1", [
        generation_floor
      ])

      Repo.transaction(fn ->
        Repo.query!("DELETE FROM platform.exposure_reconciliation_checks")

        Repo.query!(
          "INSERT INTO platform.exposure_reconciliation_checks SELECT * FROM jsonb_populate_recordset(NULL::platform.exposure_reconciliation_checks, $1)",
          [saved]
        )
      end)
    end)

    baseline = live_snapshot!(conn, %{})
    {:ok, job} = %{} |> ExposureReconciliationWorker.new() |> Oban.insert()
    live_enumerate!(job, 10)

    scopes =
      Repo.query!(
        "SELECT device_ord FROM platform.exposure_reconciliation_checks WHERE device_ord > 0 ORDER BY device_ord"
      ).rows

    assert length(scopes) <= 2_000

    for [ordinal] <- scopes do
      assert :ok =
               ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => ordinal}})
    end

    assert {:ok, %{ready: true, generation: ^baseline}} = ExposureReadiness.status()

    update_assessment!(ctx.device_uid, cve, severity: "medium")

    assert {:snooze, 30} =
             ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => scope}})

    successor = live_snapshot!(conn, %{"device_ord" => scope})
    assert successor > baseline
    assert {:ok, %{ready: false, reasons: reasons}} = ExposureReadiness.status()
    assert :comparison_pending in reasons
    assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => scope}})
    assert {:ok, %{ready: true, generation: ^successor}} = ExposureReadiness.status(scope)
    assert {:ok, %{ready: true, generation: ^baseline}} = ExposureReadiness.status()

    update_assessment!(other_ctx.device_uid, "EXAMPLE-LIVE-COVERAGE", severity: "critical")

    assert {:snooze, 30} =
             ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => other}})

    assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)
    assert {:ok, %{ready: false}} = ExposureReadiness.status()
    live_snapshot!(conn, %{"device_ord" => other})
    assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => other}})
    assert {:ok, %{ready: true}} = ExposureReadiness.status()

    Repo.query!(
      "UPDATE platform.exposure_reconciliation_checks SET checked_at = now() - interval '2 days' WHERE device_ord = 0"
    )

    assert {:ok, %{ready: false}} = ExposureReadiness.status()
    assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)
  end

  defp live_enumerate!(job, attempts) do
    assert attempts > 0, "fleet enumeration exceeded its bounded fixture budget"

    case ExposureReconciliationWorker.perform(job) do
      :ok -> :ok
      {:snooze, 1} -> live_enumerate!(job, attempts - 1)
      other -> flunk("fleet enumeration failed: #{inspect(other)}")
    end
  end

  defp live_union_paging!(conn, ctx) do
    first = 4_294_966_000
    upper = 4_294_967_295
    # Alternating CNPG-only and warehouse-only scopes make neither half sufficient.
    source = Enum.map(0..249, &(first + 2 * &1))
    stored = Enum.map(0..249, &(first + 2 * &1 + 1)) ++ [upper]
    ordinals = source ++ stored

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM platform.exposure_reconciliation_checks WHERE device_ord = ANY($1::bigint[])",
               [ordinals]
             ).rows

    [[saved_fleet]] =
      Repo.query!(
        "SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) FROM platform.exposure_reconciliation_checks c WHERE device_ord = 0"
      ).rows

    {:ok, job} = %{"cursor" => first - 1} |> ExposureReconciliationWorker.new() |> Oban.insert()
    # A previous completed enumeration job remains available when driven manually.
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [args: %{"cursor" => first - 1}]
    )

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM oban_jobs WHERE id = $1 OR (worker = 'ServiceRadar.Inventory.ExposureReconciliationWorker' AND (args->>'device_ord')::bigint = ANY($2::bigint[]))",
        [job.id, ordinals]
      )

      Repo.query!(
        "DELETE FROM platform.exposure_reconciliation_checks WHERE device_ord = ANY($1::bigint[]) OR device_ord = 0",
        [ordinals]
      )

      Repo.query!(
        "INSERT INTO platform.exposure_reconciliation_checks SELECT * FROM jsonb_populate_recordset(NULL::platform.exposure_reconciliation_checks, $1)",
        [saved_fleet]
      )
    end)

    Repo.query!(
      "INSERT INTO platform.exposure_reconciliation_checks (device_ord, inserted_at, updated_at) SELECT unnest($1::bigint[]), now(), now()",
      [source]
    )

    assert {:ok, _} = ExposureTransitionRelay.relay_once()
    live_transition!(conn, inflight_transition(ctx, upper, 41, "resolved", 1))

    values =
      Enum.map_join(
        Enum.drop(stored, -1),
        ",",
        &"(#{&1},1,1,0,'2026-10-26 00:00:00',1,1,'2026-10-26 00:00:00')"
      )

    assert {:ok, _} =
             MySQL.query(
               "INSERT INTO exposure_retired_ordinals (device_ord,transition_seq,transition_xid,state,updated_at,retired_seq,retired_xid,retired_at) VALUES " <>
                 values
             )

    assert {:ok, rows} = SnapshotWarehouse.device_ordinals(first - 1)
    assert Enum.map(rows, & &1["device_ord"]) == stored
    assert {:snooze, 1} = ExposureReconciliationWorker.perform(job)
    assert Repo.get!(Oban.Job, job.id).args["cursor"] == first + 499

    assert [[500]] =
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Inventory.ExposureReconciliationWorker' AND (args->>'device_ord')::bigint = ANY($1::bigint[])",
               [ordinals]
             ).rows

    assert {:snooze, 1} = ExposureReconciliationWorker.perform(job)
    assert Repo.get!(Oban.Job, job.id).args["cursor"] == upper
    assert :ok = ExposureReconciliationWorker.perform(job)

    assert [[501]] =
             Repo.query!(
               "SELECT count(*) FROM oban_jobs WHERE worker = 'ServiceRadar.Inventory.ExposureReconciliationWorker' AND (args->>'device_ord')::bigint = ANY($1::bigint[])",
               [ordinals]
             ).rows
  end

  defp live_delivery_orders!(conn, ctx) do
    assert {:ok, _} = ExposureTransitionRelay.relay_once()

    for live_first? <- [false, true] do
      ordinal = if live_first?, do: 4_294_965_001, else: 4_294_965_002
      owner = Ecto.UUID.generate()
      [[visible_xid]] = Repo.query!("SELECT pg_current_xact_id()::text").rows
      [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows
      [[post_xid]] = Repo.query!("SELECT pg_current_xact_id()::text").rows
      visible_xid = String.to_integer(visible_xid)
      post_xid = String.to_integer(post_xid)

      assert [[true, false]] =
               Repo.query!(
                 "SELECT pg_visible_in_snapshot($1::text::xid8, $3::text::pg_snapshot), pg_visible_in_snapshot($2::text::xid8, $3::text::pg_snapshot)",
                 [Integer.to_string(visible_xid), Integer.to_string(post_xid), view]
               ).rows

      {:ok, generation} =
        ExposureSnapshotState.create(
          ordinal,
          view,
          owner,
          System.system_time(:millisecond) + 30_000
        )

      id = generation["id"]

      on_exit(fn ->
        Repo.query!("DELETE FROM platform.exposure_snapshot_generations WHERE id = $1", [id])
      end)

      assert {:ok, 1} =
               generation
               |> snapshot_control("start", %{"snapshot" => view})
               |> live_snapshot_input!(conn)

      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "lifecycle")
      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "facts")

      bucket =
        ctx.device_uid |> ExposureTransitionRelay.subject() |> String.split(".") |> List.last()

      seen = inflight_transition(ctx, ordinal, 40, "active", visible_xid)

      page =
        Snapshot.page(generation, "device-" <> bucket, Snapshot.empty_receipt(), "facts", [seen])

      {:ok, _body, hash} = Snapshot.encode(page)
      assert {:ok, _} = ExposureSnapshotState.reserve(id, owner, page, hash)
      resolved = inflight_transition(ctx, ordinal, 41, "resolved", post_xid)
      if live_first?, do: live_transition!(conn, resolved)
      assert {:ok, 1} = page |> snapshot_message() |> live_snapshot_input!(conn)
      if !live_first?, do: live_transition!(conn, resolved)

      assert {:ok, %{rows: [[41, 0]]}} =
               MySQL.query(
                 "SELECT transition_seq,state FROM exposure_facts WHERE device_ord = #{ordinal}"
               )

      {:ok, received} = ExposureSnapshotState.get(id)
      {:ok, finished} = ExposureSnapshotState.end_manifest(id, owner, received["receipts"])

      assert {:ok, 1} =
               finished
               |> snapshot_control("end", %{"manifest" => received["receipts"]})
               |> live_snapshot_input!(conn)

      live_finalize!(id, 5)
      live_transition!(conn, inflight_transition(ctx, ordinal, 42, "resolved", post_xid))

      assert {:ok, %{rows: [[42, 0]]}} =
               MySQL.query(
                 "SELECT transition_seq,state FROM exposure_facts WHERE device_ord = #{ordinal}"
               )

      assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(id)
    end
  end

  defp live_snapshot_input!([message], conn) do
    position = message.metadata.jetstream_ack.stream_sequence

    assert %{"message" => %{"data" => encoded}} =
             ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_RECOVERY", %{
               seq: position
             })

    ExposureSnapshots.process_batch([%{message | data: Base.decode64!(encoded)}])
  end

  defp live_transition!(conn, payload) do
    subject = ExposureTransitionRelay.subject(payload["device_uid"])
    assert %{"seq" => position} = ExposureBroker.request(conn, subject, payload)

    assert %{"message" => %{"data" => encoded}} =
             ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_TRANSITIONS", %{
               seq: position
             })

    assert {:ok, 1} =
             ExposureTransitions.process_batch([
               %{
                 data: Base.decode64!(encoded),
                 metadata: %{
                   subject: subject,
                   jetstream_ack: %{stream: "EXPOSURE_TRANSITIONS", stream_sequence: position}
                 }
               }
             ])
  end

  defp live_snapshot_messages!(conn) do
    receive do
      {:msg, %{topic: "exposure.snapshots." <> _ = subject, body: body}} ->
        if String.contains?(subject, ".plan.") do
          live_snapshot_messages!(conn)
        else
          {:ok, envelope, _} = Snapshot.decode(body)
          assert {:ok, 1} = consume_retained(conn, subject, body)

          if envelope["kind"] == "end",
            do: envelope["generation"],
            else: live_snapshot_messages!(conn)
        end
    after
      30_000 -> flunk("live snapshot publisher stopped before end marker")
    end
  end

  defp live_dimensions!(conn, ingest?) do
    sequences =
      Repo.query!("""
      SELECT transition_seq FROM platform.exposure_dimension_outbox ORDER BY id LIMIT 1000
      """).rows
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.size(sequences) > 0
    # Multiple outbox rows can replay the same sequence, and PubAck includes
    # deduplicated retries. Prove logical publication coverage from retention.
    assert {:ok, _first} = ExposureDimensionRelay.relay_once()
    assert {:ok, second} = ExposureDimensionRelay.relay_once()
    assert second.failed == 0

    assert %{"state" => %{"first_seq" => first_seq, "last_seq" => last_seq}} =
             ExposureBroker.request(conn, "$JS.API.STREAM.INFO.EXPOSURE_DIMENSIONS", %{})

    assert last_seq >= first_seq and last_seq - first_seq < 2_000

    retained =
      Enum.reduce(first_seq..last_seq, MapSet.new(), fn position, retained ->
        assert %{"message" => %{"data" => encoded}} =
                 ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_DIMENSIONS", %{
                   seq: position
                 })

        body = Base.decode64!(encoded)
        sequence = Jason.decode!(body)["transition_seq"]

        if MapSet.member?(sequences, sequence) do
          if ingest? do
            assert {:ok, 1} = ExposureDimensions.process_batch([%{data: body}])
          end

          MapSet.put(retained, sequence)
        else
          retained
        end
      end)

    assert retained == sequences
  end

  defp live_empty_table!(table, deadline) do
    assert {:ok, %{rows: [[count]]}} = MySQL.query("SELECT count(*) FROM #{table}")

    cond do
      count == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("#{table} still contains #{count} rows after TRUNCATE visibility deadline")

      true ->
        Process.sleep(20)
        live_empty_table!(table, deadline)
    end
  end

  @tag sandbox: :unboxed
  @tag :tmp_dir
  test "reconciliation detects deleted warehouse facts and requires a verified scoped snapshot before readiness",
       ctx do
    {scope, payload, dimensions} = reconciliation_source!(ctx, "EXAMPLE-RECONCILE-DELETE")
    args = %{"device_ord" => scope}
    reconciliation_queries!([], dimensions)
    assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

    assert [["mismatch", %{"source" => %{"count" => 1}, "warehouse" => %{"count" => 0}}]] =
             Repo.query!(
               "SELECT status, control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [
                 scope
               ]
             ).rows

    assert {:ok, %{ready: false, reasons: reasons}} = ExposureReadiness.status(scope)
    assert :snapshot_missing in reasons

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                   fragment("?->>'device_ord'", j.args) == ^to_string(scope)
             )
           )

    predecessor = finalizing_generation!(scope)
    {:ok, [%{fact: fact}]} = ExposureTransitions.decode([%{data: Jason.encode!(payload)}])
    {:ok, repair} = ExposureSnapshotRepairs.for_fact(fact)

    assert {:ok, :ok} =
             ExposureSnapshotState.change(predecessor, fn current ->
               {:ok, repairs} = ExposureSnapshotRepairs.publish([repair])
               {:ok, Map.put(current, "repairs", repairs), :ok}
             end)

    retire_generation!(predecessor)
    payload = publication(ctx.device_uid, "EXAMPLE-RECONCILE-DELETE")

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      {:ok, _} = Gnat.sub(conn, self(), "exposure.snapshots.>")
      snapshot_query!(fn _ -> warehouse_rows([]) end)
      publisher = Task.async(fn -> ExposureSnapshotWorker.perform(%Oban.Job{args: args}) end)
      {pages, loads} = consume_snapshot_until_end(conn, [])
      assert :ok = Task.await(publisher, 5_000)
      id = hd(pages)["generation"]
      assert :ok = ExposureSnapshotFinalizer.step(id)

      restored =
        for {"/api/serviceradar/exposure_facts/_stream_load", rows} <- loads, row <- rows, do: row

      assert [%{"transition_seq" => seq}] = restored
      assert seq == payload["transition_seq"]

      assert {:ok, %{ready: false, metrics: %{repair_pending: 1}}} =
               ExposureReadiness.status(scope)

      Repo.query!(
        """
        UPDATE oban_jobs SET state = 'discarded'
        WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker'
          AND args->>'device_ord' = $1
        """,
        [to_string(scope)]
      )

      Repo.query!(
        "DELETE FROM platform.exposure_transition_outbox WHERE device_uid = $1 AND transition_seq = $2",
        [ctx.device_uid, seq]
      )

      snapshot_query!(fn _ -> warehouse_rows([]) end)

      assert {:snooze, 30} =
               ExposureReconciliationWorker.perform(%Oban.Job{args: args})

      assert {:ok, %{"repairs" => [_]}} = ExposureSnapshotState.get(predecessor)

      assert Repo.exists?(
               from(j in Oban.Job,
                 where:
                   j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                     j.state == "available" and
                     fragment("?->>'device_ord'", j.args) == ^to_string(scope)
               )
             )

      reconciliation_queries!(restored, dimensions, restored)
      assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
      assert {:ok, %{"repairs" => []}} = ExposureSnapshotState.get(predecessor)
      assert {:ok, %{ready: true, generation: ^id}} = ExposureReadiness.status(scope)

      # Ordinary young outbox rows remain present; readiness is not an empty-outbox test.
      assert Repo.query!(
               "SELECT 1 FROM platform.exposure_transition_outbox WHERE device_uid = $1 LIMIT 1",
               [
                 ctx.device_uid
               ]
             ).rows == [[1]]

      bucket = :erlang.phash2(ctx.device_uid, 16)
      operation = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO platform.exposure_delivery_batches (bucket, stream_sequences, operation_id, phase, payload_hash)
        VALUES ($1, ARRAY[700001]::bigint[], $2::text::uuid, 'capturing', repeat('a', 64))
        """,
        [bucket, operation]
      )

      on_exit(fn ->
        Repo.query!(
          "DELETE FROM platform.exposure_delivery_batches WHERE operation_id::text = $1",
          [operation]
        )
      end)

      assert {:ok, %{ready: false, reasons: reasons}} = ExposureReadiness.status(scope)
      assert :delivery_recovery in reasons

      Repo.query!(
        "DELETE FROM platform.exposure_delivery_batches WHERE operation_id::text = $1",
        [operation]
      )

      assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)

      aborted = finalizing_generation!(scope)
      retire_generation!(aborted)

      Repo.query!(
        """
        UPDATE oban_jobs SET state = 'discarded'
        WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker'
          AND args->>'device_ord' = $1
        """,
        [to_string(scope)]
      )

      reconciliation_queries!(restored, dimensions)
      assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
      assert {:ok, %{ready: false, reasons: reasons}} = ExposureReadiness.status(scope)
      assert :snapshot_recovery in reasons

      assert Repo.exists?(
               from(j in Oban.Job,
                 where:
                   j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                     j.state == "available" and
                     fragment("?->>'device_ord'", j.args) == ^to_string(scope)
               )
             )

      Repo.query!(
        "UPDATE platform.exposure_transition_outbox SET inserted_at = now() - interval '11 minutes' WHERE device_uid = $1",
        [ctx.device_uid]
      )

      assert {:ok, %{ready: false, reasons: reasons}} = ExposureReadiness.status(scope)
      assert :outbox_stale in reasons
    end)
  end

  @tag sandbox: :unboxed
  test "current source attributes drift independently of replay and repairs wait for warehouse evidence",
       ctx do
    {scope, original, dimensions} = reconciliation_source!(ctx, "EXAMPLE-RECONCILE-CONTENT")
    {:ok, [%{fact: stored}]} = ExposureTransitions.decode([%{data: Jason.encode!(original)}])
    # An out-of-band source change bypasses the publication trigger. Replaying
    # the retained after-image would conceal it, so compare the current columns.
    Repo.transaction(fn ->
      Repo.query!("""
      ALTER TABLE platform.endpoint_vulnerability_assessments
        DISABLE TRIGGER trg_exposure_assessment_sequence,
        DISABLE TRIGGER trg_exposure_assessment_publish_update
      """)

      update_assessment!(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT",
        kev: true,
        severity: "critical"
      )

      Repo.query!("""
      ALTER TABLE platform.endpoint_vulnerability_assessments
        ENABLE TRIGGER trg_exposure_assessment_sequence,
        ENABLE TRIGGER trg_exposure_assessment_publish_update
      """)
    end)

    assert publication(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT") == original
    reconciliation_queries!([stored], dimensions)
    args = %{"device_ord" => scope}
    assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
    repaired = publication(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT")
    assert repaired["kev"] == true
    assert repaired["severity"] == "critical"
    assert repaired["transition_seq"] > original["transition_seq"]

    [[%{"repairs" => [obligation]}]] =
      Repo.query!(
        "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
        [scope]
      ).rows

    assert obligation["required"] == repaired["transition_seq"]

    completed = finalizing_generation!(scope)

    assert {:ok, :ok} =
             ExposureSnapshotState.change(completed, fn current ->
               {:ok, Map.put(current, "status", "complete"), :ok}
             end)

    Repo.query!(
      """
      UPDATE oban_jobs SET state = 'completed'
      WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker'
        AND args->>'device_ord' = $1
      """,
      [to_string(scope)]
    )

    # Source publication and PubAck do not discharge a retained obligation.
    Repo.query!("DELETE FROM platform.exposure_transition_outbox WHERE device_uid = $1", [
      ctx.device_uid
    ])

    snapshot_query!(fn _ -> warehouse_rows([stored]) end)
    assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})
    assert publication(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT") == repaired
    assert {:ok, %{ready: false, metrics: %{repair_pending: 1}}} = ExposureReadiness.status(scope)

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                   j.state == "available" and
                   fragment("?->>'device_ord'", j.args) == ^to_string(scope)
             )
           )

    assert [[%{"repairs" => [^obligation]}]] =
             Repo.query!(
               "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [scope]
             ).rows

    {:ok, [%{fact: confirmed}]} = ExposureTransitions.decode([%{data: Jason.encode!(repaired)}])
    reconciliation_queries!([confirmed], dimensions, [confirmed])
    assert :ok = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

    assert [["matched", %{"repairs" => []}]] =
             Repo.query!(
               "SELECT status, control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [
                 scope
               ]
             ).rows

    assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)

    old_package = Enum.find(dimensions, &(&1["dimension"] == "package"))
    old_key = old_package["pkgver_ord"]
    cve_dimensions = Enum.reject(dimensions, &(&1["dimension"] == "package"))
    reconciliation_queries!([confirmed], cve_dimensions)
    assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

    [[%{"repairs" => [dimension_repair]}]] =
      Repo.query!(
        "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
        [scope]
      ).rows

    assert dimension_repair["kind"] == "package"
    assert dimension_repair["key"] == old_key
    assert dimension_repair["required"] == old_package["transition_seq"]

    Repo.query!(
      "DELETE FROM platform.exposure_dimension_outbox WHERE kind = 'package' AND ordinal = $1",
      [old_key]
    )

    update_assessment!(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT", installed_version: "2.0.0")
    upgraded = publication(ctx.device_uid, "EXAMPLE-RECONCILE-CONTENT")
    refute upgraded["pkgver_ord"] == old_key

    assert {:ok, current_dimensions} =
             DirectSession.run(fn reader ->
               ExposureSnapshotWorker.source_page(reader, "dimensions", scope, nil)
             end)

    refute Enum.any?(current_dimensions, fn [key, _] -> key == ["package", old_key] end)
    current_dimensions = Enum.map(current_dimensions, fn [_, payload] -> payload end)

    assert Repo.query!(
             """
             SELECT 1 FROM platform.exposure_fact_watermarks
             WHERE device_uid = $1 AND (payload->>'pkgver_ord')::bigint = $2
             """,
             [ctx.device_uid, old_key]
           ).rows == []

    for _ <- 1..2 do
      reconciliation_queries!([], current_dimensions)
      assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

      assert [[^old_package]] =
               Repo.query!(
                 "SELECT payload FROM platform.exposure_dimension_outbox WHERE kind = 'package' AND ordinal = $1",
                 [old_key]
               ).rows

      assert [[%{"repairs" => [^dimension_repair]}]] =
               Repo.query!(
                 "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
                 [scope]
               ).rows

      assert {:ok, %{ready: false, metrics: %{repair_pending: 1}}} =
               ExposureReadiness.status(scope)

      Repo.query!(
        "DELETE FROM platform.exposure_dimension_outbox WHERE kind = 'package' AND ordinal = $1",
        [old_key]
      )
    end

    {:ok, [%{fact: upgraded_fact}]} =
      ExposureTransitions.decode([%{data: Jason.encode!(upgraded)}])

    reconciliation_queries!([upgraded_fact], [old_package | current_dimensions])
    assert {:snooze, 30} = ExposureReconciliationWorker.perform(%Oban.Job{args: args})

    assert [[%{"repairs" => []}]] =
             Repo.query!(
               "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [scope]
             ).rows

    assert {:ok, %{metrics: %{repair_pending: 0}}} = ExposureReadiness.status(scope)
  end

  @tag sandbox: :unboxed
  test "deployment readiness uses each device's covering generation without losing baseline or fleet gates",
       ctx do
    {scope, _payload, _dimensions} = reconciliation_source!(ctx, "EXAMPLE-READINESS-SCOPED")

    [[saved]] =
      Repo.query!(
        "SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) FROM platform.exposure_reconciliation_checks c"
      ).rows

    {prior_generation, _} = ExposureReadiness.latest_generation(nil)
    baseline = finalizing_generation!(nil)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.exposure_snapshot_generations WHERE id = $1", [baseline])

      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO platform.exposure_reconciliation_checks
          SELECT * FROM jsonb_populate_recordset(NULL::platform.exposure_reconciliation_checks, $1)
          ON CONFLICT (device_ord) DO UPDATE SET
            status = EXCLUDED.status, control = EXCLUDED.control,
            checked_at = EXCLUDED.checked_at, updated_at = EXCLUDED.updated_at
          """,
          [saved]
        )
      end)
    end)

    assert {:ok, :ok} =
             ExposureSnapshotState.change(baseline, fn current ->
               {:ok, Map.put(current, "status", "complete"), :ok}
             end)

    inserted =
      Repo.query!("""
      INSERT INTO platform.exposure_reconciliation_checks (device_ord, inserted_at, updated_at)
      SELECT ordinal, now(), now() FROM platform.device_fleet_ordinals
      UNION SELECT 0, now(), now()
      ON CONFLICT DO NOTHING
      RETURNING device_ord
      """).rows

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.exposure_reconciliation_checks WHERE device_ord = ANY($1::bigint[])",
        [List.flatten(inserted)]
      )
    end)

    Repo.query!("""
    UPDATE platform.exposure_reconciliation_checks
    SET status = 'matched', checked_at = now(),
      control = jsonb_build_object('started_at', now() AT TIME ZONE 'utc')
    """)

    aborted = finalizing_generation!(scope)
    retire_generation!(aborted)
    successor = finalizing_generation!(scope)

    assert {:ok, :ok} =
             ExposureSnapshotState.change(successor, fn current ->
               {:ok, Map.put(current, "status", "complete"), :ok}
             end)

    Repo.query!(
      """
      UPDATE platform.exposure_reconciliation_checks
      SET control = control || jsonb_build_object('generation_floor', $2::bigint)
      WHERE device_ord = $1
      """,
      [scope, baseline]
    )

    assert {:ok, %{reasons: reasons}} = ExposureReadiness.status()
    assert :comparison_pending in reasons

    Repo.query!(
      """
      UPDATE platform.exposure_reconciliation_checks
      SET checked_at = now(), control = control || jsonb_build_object('started_at', now() AT TIME ZONE 'utc')
      WHERE device_ord = $1
      """,
      [scope]
    )

    assert {:ok, %{reasons: reasons, generation: ^baseline}} = ExposureReadiness.status()
    refute :comparison_pending in reasons
    refute :snapshot_recovery in reasons
    refute ExposureReadiness.replacement_required?(nil)
    assert {:ok, %{ready: true, generation: ^successor}} = ExposureReadiness.status(scope)

    other_scope = 4_200_000_124

    Repo.query!(
      """
      INSERT INTO platform.exposure_reconciliation_checks
        (device_ord, status, checked_at, control, inserted_at, updated_at)
      VALUES ($1, 'matched', now(), jsonb_build_object(
        'started_at', now() AT TIME ZONE 'utc', 'generation_floor', $2::bigint), now(), now())
      """,
      [other_scope, baseline]
    )

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.exposure_reconciliation_checks WHERE device_ord = $1", [
        other_scope
      ])
    end)

    assert {:ok, %{reasons: reasons}} = ExposureReadiness.status()
    assert :comparison_pending in reasons
    assert {:ok, %{ready: true}} = ExposureReadiness.status(scope)

    Repo.query!("DELETE FROM platform.exposure_reconciliation_checks WHERE device_ord = $1", [
      other_scope
    ])

    Repo.query!(
      "UPDATE platform.exposure_reconciliation_checks SET status = 'deferred' WHERE device_ord = 0"
    )

    assert {:ok, %{reasons: reasons}} = ExposureReadiness.status()
    assert :comparison_pending in reasons

    retire_generation!(baseline)
    assert {:ok, %{reasons: reasons, generation: ^prior_generation}} = ExposureReadiness.status()
    assert :snapshot_missing in reasons == (prior_generation == 0)
  end

  @tag sandbox: :unboxed
  test "comparison preserves a live resolution committed after its source view", ctx do
    {scope, original, dimensions} = reconciliation_source!(ctx, "EXAMPLE-RECONCILE-LIVE")
    parent = self()

    reconciliation_queries!([], dimensions, [], fn ->
      update_assessment!(ctx.device_uid, "EXAMPLE-RECONCILE-LIVE", status: "resolved")
      send(parent, {:resolved, publication(ctx.device_uid, "EXAMPLE-RECONCILE-LIVE")})
    end)

    assert {:snooze, 30} =
             ExposureReconciliationWorker.perform(%Oban.Job{args: %{"device_ord" => scope}})

    assert_receive {:resolved, live}
    assert live["transition_seq"] > original["transition_seq"]
    assert live["state"] == "resolved"
    assert publication(ctx.device_uid, "EXAMPLE-RECONCILE-LIVE") == live

    assert [["mismatch"]] =
             Repo.query!(
               "SELECT status FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [scope]
             ).rows
  end

  test "fleet enumeration includes warehouse-only ordinals and resumes after a bounded page",
       _ctx do
    snapshot_http!()
    completed = finalizing_generation!(nil)

    assert {:ok, :ok} =
             ExposureSnapshotState.change(completed, fn current ->
               {:ok, Map.put(current, "status", "complete"), :ok}
             end)

    aborted = finalizing_generation!(nil)
    retire_generation!(aborted)
    warehouse_only = 4_200_000_123
    snapshot_query!(fn _ -> warehouse_rows([%{"device_ord" => warehouse_only}]) end)

    {:ok, job} =
      %{"cursor" => warehouse_only - 1} |> ExposureReconciliationWorker.new() |> Oban.insert()

    assert {:snooze, 1} = ExposureReconciliationWorker.perform(job)
    assert %{"cursor" => ^warehouse_only} = Repo.get!(Oban.Job, job.id).args

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker" and
                   j.state == "available" and j.args == ^%{}
             )
           )

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == "ServiceRadar.Inventory.ExposureReconciliationWorker" and
                   fragment("?->>'device_ord'", j.args) == ^to_string(warehouse_only)
             )
           )

    assert [["deferred"]] =
             Repo.query!(
               "SELECT status FROM platform.exposure_reconciliation_checks WHERE device_ord = $1",
               [
                 warehouse_only
               ]
             ).rows

    snapshot_query!(fn _ -> warehouse_rows([]) end)
    assert :ok = ExposureReconciliationWorker.perform(job)
  end

  defp reconciliation_source!(ctx, cve, mock_warehouse? \\ true) do
    if mock_warehouse?, do: snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, cve)
    payload = publication(ctx.device_uid, cve)
    scope = payload["device_ord"]

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.exposure_reconciliation_checks WHERE device_ord = $1", [
        scope
      ])

      Repo.query!(
        "DELETE FROM platform.exposure_snapshot_generations WHERE (control->>'scope')::bigint = $1",
        [scope]
      )

      Repo.query!(
        "DELETE FROM oban_jobs WHERE worker IN ('ServiceRadar.Inventory.ExposureSnapshotWorker', 'ServiceRadar.Inventory.ExposureReconciliationWorker') AND args->>'device_ord' = $1",
        [to_string(scope)]
      )

      cleanup_source(ctx, package)
    end)

    dimensions =
      Enum.map(
        Repo.query!(
          """
          SELECT payload FROM platform.exposure_dimension_state
          WHERE (kind = 'cve' AND ordinal = $1) OR (kind = 'package' AND ordinal = $2)
          """,
          [payload["cve_ord"], payload["pkgver_ord"]]
        ).rows,
        &hd/1
      )

    {scope, payload, dimensions}
  end

  # Transport fixture only: queued fact pages and independent dimension after-images.
  # SQL cursor semantics are also exercised against scratch StarRocks before publication.
  defp reconciliation_queries!(facts, dimensions, repair_rows \\ [], before_scan \\ fn -> :ok end) do
    {:ok, decoded} =
      ExposureDimensions.decode(Enum.map(dimensions, &%{data: Jason.encode!(&1)}))

    {:ok, queue} =
      Agent.start_link(fn ->
        if(repair_rows == [], do: [facts, []], else: [repair_rows, facts, []])
      end)

    on_exit(fn -> if Process.alive?(queue), do: Agent.stop(queue) end)

    snapshot_query!(fn sql ->
      cond do
        String.contains?(sql, "exposure_cve_dim") ->
          warehouse_rows(for {:cve, _, row} <- decoded, do: row)

        String.contains?(sql, "exposure_package_dim") ->
          warehouse_rows(for {:package, _, row} <- decoded, do: row)

        String.contains?(sql, "exposure_retired_ordinals") ->
          warehouse_rows([])

        true ->
          rows =
            Agent.get_and_update(queue, fn
              [head | tail] -> {head, tail}
              [] -> {[], []}
            end)

          before_scan.()
          warehouse_rows(rows)
      end
    end)
  end

  @tag :tmp_dir
  test "snapshot receipts wait for warehouse confirmation and reject gaps, conflicts and early end markers",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, "EXAMPLE-SNAPSHOT-RECEIPT")
    payload = publication(ctx.device_uid, "EXAMPLE-SNAPSHOT-RECEIPT")
    lane = "device-#{:erlang.phash2(ctx.device_uid, 16)}"
    owner = Ecto.UUID.generate()
    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    {:ok, generation} =
      ExposureSnapshotState.create(
        payload["device_ord"],
        view,
        owner,
        System.system_time(:millisecond) + 30_000
      )

    id = generation["id"]

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      assert {:ok, 1} =
               generation
               |> snapshot_control("start", %{"snapshot" => view})
               |> ExposureSnapshots.process_batch()

      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "lifecycle")
      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "facts")
      page = Snapshot.page(generation, lane, Snapshot.empty_receipt(), "facts", [payload])
      {:ok, body, hash} = Snapshot.encode(page)

      assert {:error, :exposure_snapshot_page_not_reserved} =
               page
               |> Map.put("page", 2)
               |> snapshot_message()
               |> ExposureSnapshots.process_batch()

      assert {:error, :exposure_snapshot_incomplete} =
               generation
               |> snapshot_control("end", %{"manifest" => Snapshot.empty_manifest()})
               |> ExposureSnapshots.process_batch()

      assert {:ok, _} = ExposureSnapshotState.reserve(id, owner, page, hash)
      message = snapshot_message(page)
      task = Task.async(fn -> ExposureSnapshots.process_batch(message) end)

      assert_receive {:load, http, "/api/serviceradar/exposure_facts/_stream_load", _, [row]},
                     5_000

      assert row["snapshot_generation"] == id
      assert {:ok, pending} = ExposureSnapshotState.get(id)
      assert pending["receipts"][lane]["page"] == 0
      assert pending["pending"][lane]["state"] == "applying"

      assert {:error, :exposure_snapshot_incomplete} =
               ExposureSnapshotState.end_manifest(id, owner, Snapshot.empty_manifest())

      refute Task.yield(task, 20)
      send(http, :commit)
      assert {:ok, 1} = Task.await(task)
      assert {:ok, received} = ExposureSnapshotState.get(id)
      assert received["receipts"][lane] == %{"page" => 1, "count" => 1, "digest" => hash}
      assert received["pending"] == %{}
      assert :missing = ExposureRecovery.fetch_envelope(Snapshot.subject(id, lane, 1), hash)
      assert {:ok, 1} = ExposureSnapshots.process_batch(snapshot_message(page))
      changed = put_in(page, ["records"], [Map.put(payload, "kev", !payload["kev"])])

      assert {:error, :exposure_snapshot_receipt_conflict} =
               ExposureSnapshots.process_batch(snapshot_message(changed))

      # Delete rejected test messages so their distinct bytes do not occupy
      # the exact-subject slot needed by the valid end marker.
      assert :ok = delete_snapshot_subject(id, "end")
      assert {:ok, finished} = ExposureSnapshotState.end_manifest(id, owner, received["receipts"])

      assert {:ok, 1} =
               finished
               |> snapshot_control("end", %{"manifest" => received["receipts"]})
               |> ExposureSnapshots.process_batch()

      # A warehouse row missed by this generation needs a durable repair, even
      # when the publisher and every page have already finished successfully.
      unseen = row |> Map.put("snapshot_generation", 0) |> Map.put("transition_xid", 3)
      snapshot_query!(fn _sql -> warehouse_rows([unseen]) end)

      assert {:error, :exposure_snapshot_finalization_pending} =
               ExposureSnapshotFinalizer.step(id)

      assert {:ok, scanned} = ExposureSnapshotState.get(id)
      assert scanned["cursor"] == SnapshotWarehouse.key(unseen)
      assert [_] = scanned["repairs"]

      assert {:error, :exposure_snapshot_repairs_pending} = ExposureSnapshotFinalizer.step(id)
      assert {:ok, repairing} = ExposureSnapshotState.get(id)
      assert [required] = repairing["repairs"]
      assert required["required"] > row["transition_seq"]
      assert repairing["status"] == "finalizing"

      # Each step reloads CNPG state. A replacement finalizer must retain the
      # assigned repair rather than minting another sequence or rescanning.
      assert {:error, :exposure_snapshot_repairs_pending} = ExposureSnapshotFinalizer.step(id)
      assert {:ok, resumed} = ExposureSnapshotState.get(id)
      assert resumed["repairs"] == repairing["repairs"]
      assert resumed["cursor"] == repairing["cursor"]
      repaired = publication(ctx.device_uid, "EXAMPLE-SNAPSHOT-RECEIPT")
      assert repaired["transition_seq"] == required["required"]
      {:ok, [%{fact: confirmed}]} = ExposureTransitions.decode([%{data: Jason.encode!(repaired)}])
      snapshot_query!(fn _sql -> warehouse_rows([confirmed]) end)
      assert :ok = ExposureSnapshotFinalizer.step(id)
      assert {:ok, %{"status" => "finalizing", "repairs" => []}} = ExposureSnapshotState.get(id)
      snapshot_query!(fn _sql -> warehouse_rows([]) end)
      assert :ok = ExposureSnapshotFinalizer.step(id)
      assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(id)
      assert Snapshot.digest(body) == hash
      refute_received {:load, _, "/api/serviceradar/exposure_transitions_log/_stream_load", _, _}
    end)
  end

  test "snapshot drift creates a fresh source publication and PubAck or equal-sequence wrong content cannot discharge it",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    cve = "EXAMPLE-SNAPSHOT-REPAIR"
    insert_assessment!(ctx, package, cve)
    original = publication(ctx.device_uid, cve)
    {:ok, [%{fact: fact}]} = ExposureTransitions.decode([%{data: Jason.encode!(original)}])

    request = %{
      "key" => SnapshotWarehouse.key(fact),
      "observed" => original["transition_seq"],
      "source" => [ctx.device_uid, original["package_identity_key"], cve]
    }

    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    post_xid =
      DirectSession.run(fn session ->
        %{rows: [[xid]]} = Postgrex.query!(session, "SELECT pg_current_xact_id()::text", [])
        String.to_integer(xid)
      end)

    generation = %{"id" => 1, "scope" => original["device_ord"], "snapshot" => view}

    envelope =
      Snapshot.page(
        generation,
        "device-#{:erlang.phash2(ctx.device_uid, 16)}",
        Snapshot.empty_receipt(),
        "facts",
        [
          original
        ]
      )

    query_facts = fn row ->
      snapshot_query!(fn sql ->
        if String.contains?(sql, "exposure_retired_ordinals"),
          do: warehouse_rows([]),
          else: warehouse_rows([row])
      end)
    end

    query_facts.(fact)

    assert {:ok, %{"rows" => [marked], "repairs" => []}} =
             SnapshotWarehouse.plan(generation, envelope)

    assert marked["snapshot_generation"] == 1

    fact
    |> Map.put("transition_seq", original["transition_seq"] + 1)
    |> Map.put("transition_xid", post_xid)
    |> query_facts.()

    assert {:ok, %{"rows" => [], "repairs" => [], "post_snapshot" => 1}} =
             SnapshotWarehouse.plan(generation, envelope)

    fact
    |> Map.put("transition_seq", original["transition_seq"] + 1)
    |> Map.put("transition_xid", 3)
    |> query_facts.()

    assert {:ok, %{"rows" => [], "repairs" => [_]}} = SnapshotWarehouse.plan(generation, envelope)
    query_facts.(Map.put(fact, "kev", !fact["kev"]))

    assert {:ok, %{"rows" => [], "repairs" => [^request]}} =
             SnapshotWarehouse.plan(generation, envelope)

    assert {:ok, {:ok, [repair]}} =
             Repo.transaction(fn -> ExposureSnapshotRepairs.publish([request]) end)

    assert repair["required"] > original["transition_seq"]
    updated = publication(ctx.device_uid, cve)
    assert updated["transition_seq"] == repair["required"]

    assert {:ok, %{failed: 0}} =
             ExposureTransitionRelay.relay_once(
               batch_size: 10_000,
               publish: fn _, _, _ -> :ok end
             )

    assert {:ok, [^repair]} = ExposureSnapshotRepairs.verify([repair])
    snapshot_query!(fn _sql -> warehouse_rows([]) end)
    assert {:ok, [^repair]} = ExposureSnapshotRepairs.verify([repair])
    {:ok, [%{fact: repaired}]} = ExposureTransitions.decode([%{data: Jason.encode!(updated)}])
    snapshot_query!(fn _sql -> warehouse_rows([Map.put(repaired, "kev", !repaired["kev"])]) end)
    assert {:ok, [^repair]} = ExposureSnapshotRepairs.verify([repair])
    snapshot_query!(fn _sql -> warehouse_rows([repaired]) end)
    assert {:ok, []} = ExposureSnapshotRepairs.verify([repair])

    for {kind, ordinal} <- [{"cve", updated["cve_ord"]}, {"package", updated["pkgver_ord"]}] do
      [[before]] =
        Repo.query!(
          "SELECT payload FROM platform.exposure_dimension_state WHERE kind = $1 AND ordinal = $2",
          [
            kind,
            ordinal
          ]
        ).rows

      assert {:ok, {:ok, [assigned]}} =
               Repo.transaction(fn ->
                 ExposureSnapshotRepairs.publish([
                   %{"kind" => kind, "key" => ordinal, "observed" => before["transition_seq"]}
                 ])
               end)

      [[after_repair]] =
        Repo.query!(
          "SELECT payload FROM platform.exposure_dimension_state WHERE kind = $1 AND ordinal = $2",
          [
            kind,
            ordinal
          ]
        ).rows

      assert assigned["required"] == after_repair["transition_seq"]
      assert after_repair["transition_seq"] > before["transition_seq"]

      assert Map.drop(before, ["transition_seq", "updated_at"]) ==
               Map.drop(after_repair, ["transition_seq", "updated_at"])

      Repo.query!(
        "DELETE FROM platform.exposure_dimension_outbox WHERE kind = $1 AND ordinal = $2",
        [kind, ordinal]
      )

      assert {:ok, {:ok, [^assigned]}} =
               Repo.transaction(fn -> ExposureSnapshotRepairs.publish([assigned]) end)

      assert [[^after_repair]] =
               Repo.query!(
                 "SELECT payload FROM platform.exposure_dimension_outbox WHERE kind = $1 AND ordinal = $2",
                 [kind, ordinal]
               ).rows

      if kind == "cve" do
        content =
          after_repair
          |> Map.take(["cve_ord", "cve_id", "epss_score"])
          |> Map.put("epss_score", 0.25)

        [[live_sequence]] =
          Repo.query!("SELECT platform.exposure_publish_dimension($1,$2,$3,false)", [
            kind,
            ordinal,
            content
          ]).rows

        assert live_sequence > assigned["required"]

        {:ok, [{_, _, confirmed}]} =
          ExposureDimensions.decode([%{data: Jason.encode!(after_repair)}])

        snapshot_query!(fn _sql -> warehouse_rows([confirmed]) end)

        assert {:ok, {:ok, [replayed]}} =
                 Repo.transaction(fn -> ExposureSnapshotRepairs.publish([assigned]) end)

        assert {:ok, []} = ExposureSnapshotRepairs.verify([replayed])

        assert [[true]] =
                 Repo.query!(
                   """
                   SELECT EXISTS (SELECT 1 FROM platform.exposure_dimension_outbox
                     WHERE kind = $1 AND ordinal = $2 AND transition_seq = $3)
                   """,
                   [kind, ordinal, live_sequence]
                 ).rows
      end
    end

    Repo.query!("UPDATE platform.device_fleet_ordinals SET tombstoned = true WHERE uid = $1", [
      ctx.device_uid
    ])

    [[marker]] =
      Repo.query!("SELECT platform.exposure_lifecycle_publication($1)", [updated["device_ord"]]).rows

    assert {:ok, {:ok, [assigned]}} =
             Repo.transaction(fn ->
               ExposureSnapshotRepairs.publish([
                 %{
                   "kind" => "lifecycle",
                   "key" => updated["device_ord"],
                   "observed" => marker["transition_seq"]
                 }
               ])
             end)

    [[new_marker]] =
      Repo.query!("SELECT platform.exposure_lifecycle_publication($1)", [updated["device_ord"]]).rows

    assert new_marker["state"] == "retired"
    assert new_marker["transition_seq"] == assigned["required"]
    assert new_marker["transition_seq"] > marker["transition_seq"]
    assert new_marker in transitions(ctx.device_uid)
  end

  @tag sandbox: :unboxed
  @tag :tmp_dir
  test "the publisher holds one MVCC view across phase boundaries and a lost reader starts a new generation",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    cve = "EXAMPLE-SNAPSHOT-VIEW-#{ctx.unique}"
    insert_assessment!(ctx, package, cve)
    original = publication(ctx.device_uid, cve)
    scope = original["device_ord"]

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.exposure_snapshot_generations WHERE (control->>'scope')::bigint = $1",
        [scope]
      )

      Repo.query!(
        "DELETE FROM oban_jobs WHERE worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker' AND args->>'device_ord' = $1",
        [to_string(scope)]
      )

      cleanup_source(ctx, package)
    end)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      {:ok, _} = Gnat.sub(conn, self(), "exposure.snapshots.>")
      args = %{"device_ord" => scope}
      publisher = Task.async(fn -> ExposureSnapshotWorker.perform(%Oban.Job{args: args}) end)
      assert_receive {:msg, %{topic: start_subject, body: start_body}}, 5_000
      {:ok, start, _} = Snapshot.decode(start_body)
      assert start["kind"] == "start"
      first_id = start["generation"]
      # This commit occurs after V but before the reader is allowed to page.
      update_assessment!(ctx.device_uid, cve, kev: true)
      later = publication(ctx.device_uid, cve)
      assert later["transition_seq"] > original["transition_seq"]
      assert {:ok, 1} = consume_retained(conn, start_subject, start_body)
      {pages, loads} = consume_snapshot_until_end(conn, [])
      assert :ok = Task.await(publisher, 5_000)
      facts = pages |> Enum.filter(&(&1["phase"] == "facts")) |> Enum.flat_map(& &1["records"])
      assert facts == [original]

      assert Enum.any?(loads, fn {path, rows} ->
               String.contains?(path, "exposure_facts") and
                 Enum.any?(rows, &(&1["transition_seq"] == original["transition_seq"]))
             end)

      assert {:ok, first} = ExposureSnapshotState.get(first_id)
      assert first["status"] == "finalizing"
      assert first["snapshot"] == start["snapshot"]
      assert :ok = ExposureSnapshotFinalizer.step(first_id)

      lost = Task.async(fn -> ExposureSnapshotWorker.perform(%Oban.Job{args: args}) end)
      assert_receive {:msg, %{body: lost_body}}, 5_000
      {:ok, lost_start, _} = Snapshot.decode(lost_body)
      assert lost_start["kind"] == "start"
      # Kill the reader while it waits for start receipt, before any load.
      Task.shutdown(lost, :brutal_kill)
      assert :ok = ExposureSnapshotWorker.recover_reader()
      assert {:ok, %{"status" => "aborted"}} = ExposureSnapshotState.get(lost_start["generation"])
      replacement = Task.async(fn -> ExposureSnapshotWorker.perform(%Oban.Job{args: args}) end)
      assert_receive {:msg, %{topic: replacement_subject, body: replacement_body}}, 5_000
      {:ok, replacement_start, _} = Snapshot.decode(replacement_body)
      assert replacement_start["generation"] > lost_start["generation"]
      assert replacement_start["snapshot"] != lost_start["snapshot"]
      assert {:ok, 1} = consume_retained(conn, replacement_subject, replacement_body)
      {replacement_pages, _} = consume_snapshot_until_end(conn, [])
      assert :ok = Task.await(replacement, 5_000)

      assert replacement_pages
             |> Enum.filter(&(&1["phase"] == "facts"))
             |> Enum.flat_map(& &1["records"]) == [later]

      assert :ok = ExposureSnapshotFinalizer.step(replacement_start["generation"])
    end)
  end

  defp consume_snapshot_until_end(conn, pages, loads \\ []) do
    receive do
      {:msg, %{topic: subject, body: body}} ->
        if String.contains?(subject, ".plan.") do
          consume_snapshot_until_end(conn, pages, loads)
        else
          {:ok, envelope, _} = Snapshot.decode(body)
          task = Task.async(fn -> consume_retained(conn, subject, body) end)
          {{:ok, 1}, written} = answer_snapshot_loads(task)

          if envelope["kind"] == "end" do
            {Enum.reverse(pages), loads ++ written}
          else
            consume_snapshot_until_end(conn, [envelope | pages], loads ++ written)
          end
        end
    after
      10_000 -> flunk("snapshot publisher stopped before a complete end marker")
    end
  end

  defp consume_retained(conn, subject, body) do
    %{"message" => %{"seq" => position}} =
      ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_RECOVERY", %{
        last_by_subj: subject
      })

    ExposureSnapshots.process_batch([
      %{
        data: body,
        metadata: %{
          subject: subject,
          jetstream_ack: %{stream: "EXPOSURE_RECOVERY", stream_sequence: position}
        }
      }
    ])
  end

  defp answer_snapshot_loads(task, loads \\ []) do
    ref = task.ref

    receive do
      {:load, http, path, _headers, rows} ->
        send(http, :commit)
        answer_snapshot_loads(task, [{path, rows} | loads])

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {result, Enum.reverse(loads)}
    after
      10_000 -> flunk("snapshot processor did not settle")
    end
  end

  @tag :tmp_dir
  test "recovery consumption retains an owned live copy and removes a late copy after its operation ends",
       ctx do
    snapshot_http!()

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)

      assert {:error, :synthetic_unknown} =
               ExposureDelivery.run([message], fn _, _ -> {:error, :synthetic_unknown} end)

      [[id, hash, position]] =
        Repo.query!(
          "SELECT operation_id::text, payload_hash, recovery_position FROM platform.exposure_delivery_batches WHERE bucket = $1",
          [bucket]
        ).rows

      subject = "exposure.delivery.recovery.#{bucket}.#{id}"
      assert {:ok, ^position, body} = ExposureRecovery.fetch_envelope(subject, hash, position)

      copy = fn seq ->
        [
          %{
            data: body,
            metadata: %{
              subject: subject,
              jetstream_ack: %{stream: "EXPOSURE_RECOVERY", stream_sequence: seq}
            }
          }
        ]
      end

      assert {:ok, 1} = ExposureSnapshots.process_batch(copy.(position))
      assert {:ok, ^position, ^body} = ExposureRecovery.fetch_envelope(subject, hash, position)
      assert {:ok, 1} = ExposureDelivery.run([message], fn _, _ -> {:ok, 1} end)

      assert [] =
               Repo.query!("SELECT 1 FROM platform.exposure_delivery_batches WHERE bucket = $1", [
                 bucket
               ]).rows

      assert {:ok, late_position} = ExposureRecovery.retain_envelope(subject, body, hash)
      assert {:ok, 1} = ExposureSnapshots.process_batch(copy.(late_position))
      assert :missing = ExposureRecovery.fetch_envelope(subject, hash, late_position)
      refute_received {:load, _, _, _, _}
    end)
  end

  @tag :tmp_dir
  test "a deployment start accounts for unstarted gaps in empty lanes but keeps legacy uncertainty blocked",
       ctx do
    snapshot_http!()
    owner = Ecto.UUID.generate()
    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    {:ok, generation} =
      ExposureSnapshotState.create(nil, view, owner, System.system_time(:millisecond) + 30_000)

    Repo.query!(
      """
      INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences, phase, operation_id, payload_hash)
      VALUES (0, ARRAY[90001,90002]::bigint[], 'snapshot_required', $1, repeat('0', 64)),
             (1, ARRAY[90003]::bigint[], 'legacy', NULL, NULL)
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      assert {:error, _} =
               generation
               |> snapshot_control("start", %{"snapshot" => view})
               |> ExposureSnapshots.process_batch()

      assert [] =
               Repo.query!("SELECT 1 FROM platform.exposure_delivery_batches WHERE bucket = 0").rows

      assert [["legacy"]] =
               Repo.query!(
                 "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = 1"
               ).rows

      assert {:ok, state} = ExposureSnapshotState.get(generation["id"])
      assert state["history_gaps"] == 2
      refute state["started"]
      refute_received {:load, _, _, _, _}
    end)
  end

  @tag :tmp_dir
  test "verified snapshot completion continues through ordinary live journals and restarts for a late gap",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])

    [[ordinal]] =
      Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [
        ctx.device_uid
      ]).rows

    bucket =
      ctx.device_uid
      |> ExposureTransitionRelay.subject()
      |> String.split(".")
      |> List.last()
      |> String.to_integer()

    other = if bucket == 0, do: 1, else: 0
    gap = Enum.find(0..15, &(&1 not in [bucket, other]))

    empty = finalizing_generation!(nil)
    assert :ok = ExposureSnapshotFinalizer.step(empty)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(empty)

    flowing = finalizing_generation!(nil)
    insert_journal!(bucket, "capturing")
    insert_journal!(other, "complete")
    assert :ok = ExposureSnapshotFinalizer.step(flowing)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(flowing)

    assert [["capturing"], ["complete"]] =
             [bucket, other] |> journal_phases!() |> Enum.sort()

    clear_journals!([bucket, other])

    ordinary = finalizing_generation!(nil)
    insert_journal!(bucket, "applying")
    insert_journal!(other, "capturing")
    assert :ok = ExposureSnapshotFinalizer.step(ordinary)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(ordinary)
    assert [["applying"], ["capturing"]] = [bucket, other] |> journal_phases!() |> Enum.sort()
    clear_journals!([bucket, other])

    blocked = finalizing_generation!(nil)
    insert_journal!(other, "legacy")
    insert_journal!(bucket, "capturing")
    insert_journal!(gap, "snapshot_required")

    assert {:error, :exposure_snapshot_finalization_pending} =
             ExposureSnapshotFinalizer.step(blocked)

    assert {:ok, %{"status" => "finalizing", "history_gaps" => 0}} =
             ExposureSnapshotState.get(blocked)

    assert [["capturing"], ["legacy"], ["snapshot_required"]] =
             [bucket, other, gap] |> journal_phases!() |> Enum.sort()

    retire_generation!(blocked)
    clear_journals!([bucket, other, gap])

    scoped = finalizing_generation!(ordinal)
    insert_journal!(other, "legacy")
    insert_journal!(bucket, "capturing")
    assert :ok = ExposureSnapshotFinalizer.step(scoped)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(scoped)
    clear_journals!([other, bucket])

    own_legacy = finalizing_generation!(ordinal)
    insert_journal!(bucket, "legacy")

    assert {:error, :exposure_snapshot_finalization_pending} =
             ExposureSnapshotFinalizer.step(own_legacy)

    assert {:ok, %{"status" => "finalizing"}} = ExposureSnapshotState.get(own_legacy)
    retire_generation!(own_legacy)
    clear_journals!([bucket])

    own_live = finalizing_generation!(ordinal)
    insert_journal!(bucket, "applying")
    insert_journal!(other, "applying")
    assert :ok = ExposureSnapshotFinalizer.step(own_live)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(own_live)
    assert [["applying"], ["applying"]] = [bucket, other] |> journal_phases!() |> Enum.sort()
    clear_journals!([bucket, other])

    own_gap = finalizing_generation!(ordinal)
    insert_journal!(bucket, "snapshot_required")

    assert {:error, :exposure_snapshot_input_missing} =
             ExposureSnapshotFinalizer.step(own_gap)

    assert {:ok, %{"status" => "aborted", "abort_reason" => "exposure_snapshot_required"}} =
             ExposureSnapshotState.get(own_gap)

    assert [["snapshot_required"]] = journal_phases!([bucket])
    clear_journals!([bucket])

    absent = finalizing_generation!(4_000_000_001)
    insert_journal!(0, "legacy")
    insert_journal!(1, "snapshot_required")
    insert_journal!(2, "applying")
    assert :ok = ExposureSnapshotFinalizer.step(absent)
    assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(absent)
    clear_journals!([0, 1, 2])

    fenced = finalizing_generation!(nil)

    {:ok, :ok} =
      ExposureSnapshotState.change(fenced, fn current ->
        {:ok, Map.put(current, "history_gaps", 2), :ok}
      end)

    held = insert_journal!(bucket, "applying")
    insert_journal!(other, "applying")
    insert_journal!(gap, "snapshot_required")

    {:ok, :ok} =
      ExposureSnapshotState.change(fenced, fn current ->
        {:ok, Map.put(current, "retained_operations", [held]), :ok}
      end)

    assert {:error, :exposure_snapshot_finalization_pending} =
             ExposureSnapshotFinalizer.step(fenced)

    assert {:ok, %{"status" => "finalizing", "history_gaps" => 2}} =
             ExposureSnapshotState.get(fenced)

    Repo.query!(
      """
      UPDATE platform.exposure_delivery_batches
      SET phase = 'complete'
      WHERE bucket = $1 AND operation_id = $2::uuid
      """,
      [bucket, Ecto.UUID.dump!(held)]
    )

    assert {:error, :exposure_snapshot_input_missing} =
             ExposureSnapshotFinalizer.step(fenced)

    assert {:ok,
            %{
              "status" => "aborted",
              "abort_reason" => "exposure_snapshot_required",
              "history_gaps" => 2
            }} = ExposureSnapshotState.get(fenced)

    assert [["applying"], ["complete"], ["snapshot_required"]] =
             [bucket, other, gap] |> journal_phases!() |> Enum.sort()

    assert {:error, :exposure_snapshot_incomplete} = ExposureSnapshotFinalizer.step(fenced)
    assert {:ok, %{"history_gaps" => 2}} = ExposureSnapshotState.get(fenced)
    clear_journals!([bucket, other, gap])

    restart = finalizing_generation!(nil)

    repair = %{
      "kind" => "fact",
      "key" => [ordinal, 20_240_000_040, 40],
      "observed" => 40,
      "required" => 41,
      "expected" => "unverified-repair"
    }

    {:ok, :ok} =
      ExposureSnapshotState.change(restart, fn current ->
        next =
          current
          |> Map.put("history_gaps", 2)
          |> Map.put("repairs", [repair])

        {:ok, next, :ok}
      end)

    Repo.query!(
      """
      INSERT INTO platform.exposure_delivery_batches
        (bucket, stream_sequences, phase, operation_id, payload_hash)
      VALUES ($1, $2::bigint[], 'snapshot_required', $3, $4)
      """,
      [
        gap,
        [90_001, 90_002, 90_003],
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        String.duplicate("cd", 32)
      ]
    )

    assert {:error, :exposure_snapshot_input_missing} =
             ExposureSnapshotFinalizer.step(restart)

    assert {:ok, aborted} = ExposureSnapshotState.get(restart)
    assert aborted["status"] == "aborted"
    assert aborted["abort_reason"] == "exposure_snapshot_required"
    assert aborted["history_gaps"] == 2
    assert aborted["repairs"] == [repair]
    assert aborted["cursor"] == [0, 0, 0]
    assert [["snapshot_required"]] = journal_phases!([gap])

    assert {:error, :exposure_snapshot_incomplete} = ExposureSnapshotFinalizer.step(restart)

    assert {:ok, %{"history_gaps" => 2, "status" => "aborted", "repairs" => [^repair]}} =
             ExposureSnapshotState.get(restart)

    assert Enum.any?(
             Repo.all(
               from(j in Oban.Job,
                 where: j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker"
               )
             ),
             &(&1.args == %{})
           )

    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows
    owner = Ecto.UUID.generate()

    {:ok, successor} =
      ExposureSnapshotState.create(nil, view, owner, System.system_time(:millisecond) + 30_000)

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      assert {:ok, 1} =
               successor
               |> snapshot_control("start", %{"snapshot" => view})
               |> ExposureSnapshots.process_batch()

      assert {:ok, started} = ExposureSnapshotState.get(successor["id"])
      assert started["id"] != restart
      assert started["history_gaps"] == 3
      assert started["started"]
      assert [] = journal_phases!([gap])

      assert {:ok, 1} =
               successor
               |> snapshot_control("start", %{"snapshot" => view})
               |> ExposureSnapshots.process_batch()

      assert {:ok, replayed} = ExposureSnapshotState.get(successor["id"])
      assert replayed["history_gaps"] == 3

      assert {:ok, %{"history_gaps" => 2, "status" => "aborted"}} =
               ExposureSnapshotState.get(restart)
    end)
  end

  @tag :tmp_dir
  test "live sequence 41 resolves before completion and a later live transition follows it",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])

    [[ordinal]] =
      Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [
        ctx.device_uid
      ]).rows

    bucket =
      ctx.device_uid
      |> ExposureTransitionRelay.subject()
      |> String.split(".")
      |> List.last()
      |> String.to_integer()

    lane = "device-#{bucket}"
    owner = Ecto.UUID.generate()

    visible_xid =
      DirectSession.run(fn session ->
        %{rows: [[xid]]} = Postgrex.query!(session, "SELECT pg_current_xact_id()::text", [])
        String.to_integer(xid)
      end)

    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    post_xid =
      DirectSession.run(fn session ->
        %{rows: [[xid]]} = Postgrex.query!(session, "SELECT pg_current_xact_id()::text", [])
        String.to_integer(xid)
      end)

    assert [[true]] =
             Repo.query!(
               "SELECT pg_visible_in_snapshot($1::text::xid8, $2::text::pg_snapshot)",
               [Integer.to_string(visible_xid), view]
             ).rows

    assert [[false]] =
             Repo.query!(
               "SELECT pg_visible_in_snapshot($1::text::xid8, $2::text::pg_snapshot)",
               [Integer.to_string(post_xid), view]
             ).rows

    {:ok, generation} =
      ExposureSnapshotState.create(
        ordinal,
        view,
        owner,
        System.system_time(:millisecond) + 30_000
      )

    id = generation["id"]
    other = if bucket == 0, do: 1, else: 0
    fact_key = [ordinal, 20_240_000_040, 40]

    resolved = %{
      "device_ord" => ordinal,
      "cve_ord" => 20_240_000_040,
      "pkg_ord" => 40,
      "transition_seq" => 41,
      "transition_xid" => post_xid,
      "state" => 0,
      "snapshot_generation" => 0
    }

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      assert {:ok, 1} =
               generation
               |> snapshot_control("start", %{"snapshot" => view})
               |> ExposureSnapshots.process_batch()

      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "lifecycle")
      assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "facts")
      seen = inflight_transition(ctx, ordinal, 40, "active", visible_xid)
      page = Snapshot.page(generation, lane, Snapshot.empty_receipt(), "facts", [seen])
      {:ok, _body, hash} = Snapshot.encode(page)
      assert {:ok, _} = ExposureSnapshotState.reserve(id, owner, page, hash)
      task = Task.async(fn -> ExposureSnapshots.process_batch(snapshot_message(page)) end)

      assert_receive {:load, http, "/api/serviceradar/exposure_facts/_stream_load", _, [row]},
                     5_000

      assert row["transition_seq"] == 40
      assert row["state"] == 1
      assert row["snapshot_generation"] == id
      send(http, :commit)
      assert {:ok, 1} = Task.await(task)

      assert {:ok, 1} =
               deliver_transition!(
                 ctx,
                 inflight_transition(ctx, ordinal, 41, "resolved", post_xid)
               )

      held = insert_journal!(bucket, "applying")
      assert {:ok, received} = ExposureSnapshotState.get(id)

      assert {:ok, finished} =
               ExposureSnapshotState.end_manifest(id, owner, received["receipts"])

      assert {:ok, 1} =
               finished
               |> snapshot_control("end", %{"manifest" => received["receipts"]})
               |> ExposureSnapshots.process_batch()

      assert {:ok, %{"status" => "finalizing", "retained_operations" => [^held]}} =
               ExposureSnapshotState.get(id)

      insert_journal!(other, "applying")

      pages = :counters.new(1, [:atomics])

      snapshot_query!(fn _sql ->
        if :counters.get(pages, 1) == 0 do
          :counters.add(pages, 1, 1)
          warehouse_rows([resolved])
        else
          warehouse_rows([])
        end
      end)

      assert {:error, :exposure_snapshot_finalization_pending} =
               ExposureSnapshotFinalizer.step(id)

      assert {:ok, scanned} = ExposureSnapshotState.get(id)
      assert scanned["repairs"] == []
      assert scanned["cursor"] == fact_key
      assert scanned["status"] == "finalizing"

      assert {:error, :exposure_snapshot_finalization_pending} =
               ExposureSnapshotFinalizer.step(id)

      assert {:ok, waiting} = ExposureSnapshotState.get(id)
      assert waiting["repairs"] == []
      assert waiting["cursor"] == fact_key
      assert waiting["status"] == "finalizing"
      assert [["applying"], ["applying"]] = [bucket, other] |> journal_phases!() |> Enum.sort()

      Repo.query!(
        """
        UPDATE platform.exposure_delivery_batches
        SET phase = 'complete'
        WHERE bucket = $1 AND operation_id = $2::uuid
        """,
        [bucket, Ecto.UUID.dump!(held)]
      )

      assert :ok = ExposureSnapshotFinalizer.step(id)
      assert {:ok, %{"status" => "complete", "repairs" => []}} = ExposureSnapshotState.get(id)
      assert [["applying"], ["complete"]] = [bucket, other] |> journal_phases!() |> Enum.sort()

      clear_journals!([bucket])
      snapshot_query!(fn _sql -> warehouse_rows([]) end)

      later_xid =
        DirectSession.run(fn session ->
          %{rows: [[xid]]} = Postgrex.query!(session, "SELECT pg_current_xact_id()::text", [])
          String.to_integer(xid)
        end)

      assert {:ok, 1} =
               deliver_transition!(
                 ctx,
                 inflight_transition(ctx, ordinal, 42, "resolved", later_xid)
               )

      assert {:ok, %{"status" => "complete"}} = ExposureSnapshotState.get(id)
      assert [["applying"]] = journal_phases!([other])
    end)
  end

  defp finalizing_generation!(scope) do
    owner = Ecto.UUID.generate()
    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    {:ok, generation} =
      ExposureSnapshotState.create(scope, view, owner, System.system_time(:millisecond) + 30_000)

    manifest = Snapshot.empty_manifest()

    {:ok, :ok} =
      ExposureSnapshotState.change(generation["id"], fn current ->
        next =
          current
          |> Map.put("status", "finalizing")
          |> Map.put("receipts", manifest)
          |> Map.put("manifest", manifest)
          |> Map.put("pending", %{})
          |> Map.put("repairs", [])

        {:ok, next, :ok}
      end)

    generation["id"]
  end

  defp retire_generation!(id) do
    {:ok, :ok} =
      ExposureSnapshotState.change(id, fn current ->
        {:ok, Map.put(current, "status", "aborted"), :ok}
      end)
  end

  defp insert_journal!(bucket, "legacy") do
    Repo.query!(
      """
      INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences, phase)
      VALUES ($1, $2::bigint[], 'legacy')
      """,
      [bucket, [bucket]]
    )
  end

  defp insert_journal!(bucket, phase) do
    id = Ecto.UUID.generate()
    position = if phase in ["applying", "complete"], do: 1

    Repo.query!(
      """
      INSERT INTO platform.exposure_delivery_batches
        (bucket, stream_sequences, phase, operation_id, payload_hash, recovery_position)
      VALUES ($1, $2::bigint[], $3, $4, $5, $6)
      """,
      [bucket, [bucket], phase, Ecto.UUID.dump!(id), String.duplicate("ab", 32), position]
    )

    id
  end

  defp clear_journals!(buckets) do
    Enum.each(buckets, fn bucket ->
      Repo.query!("DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1", [bucket])
    end)
  end

  defp journal_phases!(buckets) do
    buckets
    |> Enum.flat_map(fn bucket ->
      Repo.query!(
        "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = $1",
        [bucket]
      ).rows
    end)
    |> Enum.sort()
  end

  defp inflight_transition(ctx, ordinal, seq, state, xid) do
    %{
      "schema_version" => 1,
      "device_uid" => ctx.device_uid,
      "device_ord" => ordinal,
      "device_lifecycle_seq" => 0,
      "cve_ord" => 20_240_000_040,
      "pkg_ord" => 40,
      "pkgver_ord" => 41,
      "transition_seq" => seq,
      "transition_xid" => xid,
      "state" => state,
      "source_scope" => "host",
      "severity" => "high",
      "cvss_score" => 7.5,
      "kev" => false,
      "exploit_available" => false,
      "fix_available" => state == "resolved",
      "first_exposed_at" => "2026-10-26T00:00:00",
      "resolved_at" => if(state == "resolved", do: "2026-10-26T00:00:41"),
      "changed_at" => "2026-10-26T00:00:#{String.pad_leading(Integer.to_string(seq), 2, "0")}",
      "package_identity_key" => "pkgkey:examplelib:#{ctx.unique}",
      "cve_id" => "EXAMPLE-INFLIGHT-40"
    }
  end

  defp deliver_transition!(ctx, payload) do
    task =
      Task.async(fn ->
        ExposureTransitions.process_batch([
          %{
            data: Jason.encode!(payload),
            metadata: %{
              subject: ExposureTransitionRelay.subject(ctx.device_uid),
              jetstream_ack: %{
                stream: "EXPOSURE_TRANSITIONS",
                stream_sequence: payload["transition_seq"]
              }
            }
          }
        ])
      end)

    assert_receive {:load, http, "/api/serviceradar/exposure_facts/_stream_load", _, [fact]},
                   5_000

    assert fact["transition_seq"] == payload["transition_seq"]
    assert fact["state"] == if(payload["state"] == "resolved", do: 0, else: 1)
    refute Map.has_key?(fact, "snapshot_generation")
    send(http, :commit)

    assert_receive {:load, log_http, "/api/serviceradar/exposure_transitions_log/_stream_load", _,
                    [history]},
                   5_000

    assert history["transition_seq"] == payload["transition_seq"]
    send(log_http, :commit)
    Task.await(task)
  end

  defp stall_applying_snapshot!(ctx, payload) do
    lane = "device-#{:erlang.phash2(ctx.device_uid, 16)}"
    owner = Ecto.UUID.generate()
    [[view]] = Repo.query!("SELECT pg_current_snapshot()::text").rows

    {:ok, generation} =
      ExposureSnapshotState.create(
        payload["device_ord"],
        view,
        owner,
        System.system_time(:millisecond) + 30_000
      )

    id = generation["id"]

    assert {:ok, 1} =
             generation
             |> snapshot_control("start", %{"snapshot" => view})
             |> ExposureSnapshots.process_batch()

    assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "lifecycle")
    assert {:ok, :ok} = ExposureSnapshotState.phase(id, owner, "facts")
    page = Snapshot.page(generation, lane, Snapshot.empty_receipt(), "facts", [payload])
    {:ok, _body, hash} = Snapshot.encode(page)
    assert {:ok, _} = ExposureSnapshotState.reserve(id, owner, page, hash)
    task = Task.async(fn -> ExposureSnapshots.process_batch(snapshot_message(page)) end)
    assert_receive {:load, http, _path, _headers, _rows}, 5_000
    send(http, :failure)
    assert {:error, _} = Task.await(task)

    assert {:ok, %{"pending" => %{^lane => %{"state" => "applying"}}}} =
             ExposureSnapshotState.get(id)

    %{id: id, lane: lane, bucket: :erlang.phash2(ctx.device_uid, 16)}
  end

  defp plant_applying_delivery!(ctx, bucket, seq) do
    message = delivery_message(ctx, seq)
    id = Ecto.UUID.generate()
    {:ok, body, hash} = ExposureRecovery.encode(bucket, id, [{seq, message}])
    {:ok, position} = ExposureRecovery.retain(bucket, id, body, hash)

    Repo.query!(
      """
      INSERT INTO platform.exposure_delivery_batches
        (bucket, stream_sequences, phase, operation_id, payload_hash, recovery_position)
      VALUES ($1, $2::bigint[], 'applying', $3, $4, $5)
      """,
      [bucket, [seq], Ecto.UUID.dump!(id), hash, position]
    )

    message
  end

  defp snapshot_http! do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
    if !Process.whereis(LoadSupervisor), do: start_supervised!(LoadSupervisor)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task, fn -> ServiceRadar.TestSupport.ExposureHTTPLoad.serve(listener, parent) end}
    )

    Application.put_env(:serviceradar_core, StarRocks,
      enabled: true,
      fe_http: "http://127.0.0.1:#{port}",
      mysql: fn _ -> warehouse_rows([]) end
    )
  end

  defp snapshot_query!(fun) do
    config = Application.get_env(:serviceradar_core, StarRocks, [])
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(config, :mysql, fun))
  end

  defp warehouse_rows([]), do: {:ok, %{columns: [], rows: []}}

  defp warehouse_rows([row | _] = rows) do
    columns = Enum.sort(Map.keys(row))

    {:ok,
     %{columns: columns, rows: Enum.map(rows, fn value -> Enum.map(columns, &value[&1]) end)}}
  end

  defp snapshot_control(generation, kind, fields) do
    snapshot_message(
      Map.merge(
        %{
          "version" => 1,
          "generation" => generation["id"],
          "scope" => generation["scope"],
          "fence" => Snapshot.digest(generation["snapshot"]),
          "kind" => kind
        },
        fields
      )
    )
  end

  defp snapshot_message(envelope) do
    {:ok, body, hash} = Snapshot.encode(envelope)

    subject =
      if envelope["kind"],
        do: "exposure.snapshots.#{envelope["generation"]}.#{envelope["kind"]}",
        else: Snapshot.subject(envelope["generation"], envelope["lane"], envelope["page"])

    {:ok, position} = ExposureRecovery.retain_envelope(subject, body, hash)

    [
      %{
        data: body,
        metadata: %{
          subject: subject,
          jetstream_ack: %{stream: "EXPOSURE_RECOVERY", stream_sequence: position}
        }
      }
    ]
  end

  defp delete_snapshot_subject(id, suffix) do
    conn = Process.whereis(ServiceRadar.NATS.Connection.connection_name())

    %{"message" => %{"seq" => position}} =
      ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_RECOVERY", %{
        last_by_subj: "exposure.snapshots.#{id}.#{suffix}"
      })

    ExposureRecovery.delete(position)
  end

  test "an actionable attribute change publishes the complete after-image with ordinals; other writes publish nothing",
       ctx do
    cve_id = "CVE-2024-0001"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    assert [entered] = transitions(ctx.device_uid)
    assert entered["state"] == "active"
    assert entered["reason"] == "entered_actionable"
    assert entered["transition_seq"] == last_transition_seq(ctx.device_uid, cve_id)
    assert entered["cve_ord"] == 20_240_000_001
    assert is_integer(entered["pkg_ord"]) and is_integer(entered["pkgver_ord"])
    assert is_integer(entered["transition_xid"])
    assert is_binary(entered["first_exposed_at"])
    assert "source_scope" in entered["changed_fields"]
    assert entered["source_scope"] == "host"
    assert publication(ctx.device_uid, cve_id) == entered

    # Metadata, timestamps and the trigger-owned sequence column are not
    # exposure state: no transition, and the sequence cannot be overwritten.
    update_assessment!(ctx.device_uid, cve_id,
      metadata: %{"note" => "refreshed"},
      last_seen_at: ~N[2026-01-02 00:00:00],
      last_transition_seq: 1
    )

    assert [_entered] = transitions(ctx.device_uid)
    assert last_transition_seq(ctx.device_uid, cve_id) == entered["transition_seq"]
    assert publication(ctx.device_uid, cve_id) == entered

    update_assessment!(ctx.device_uid, cve_id, kev: true)

    assert [_entered, kev_changed] = transitions(ctx.device_uid)
    assert kev_changed["reason"] == "actionable_attributes_changed"
    assert kev_changed["changed_fields"] == ["kev"]
    assert kev_changed["transition_seq"] > entered["transition_seq"]
    # The after-image is complete: unchanged attributes are carried too.
    assert kev_changed["kev"] == true
    assert kev_changed["severity"] == "high"
    assert kev_changed["cvss_score"] == 7.5
    assert kev_changed["pkg_ord"] == entered["pkg_ord"]
    assert kev_changed["first_exposed_at"] == entered["first_exposed_at"]

    # A candidate is not exposure: neither its creation nor its changes publish.
    insert_assessment!(ctx, endpoint_package_ref, "CVE-2024-0002",
      assessment: "candidate",
      disposition: "unknown"
    )

    update_assessment!(ctx.device_uid, "CVE-2024-0002", severity: "critical")
    assert [_entered, _kev_changed] = transitions(ctx.device_uid)
    assert publication(ctx.device_uid, cve_id) == kev_changed

    assert {:ok, %{failed: 0}} =
             ExposureTransitionRelay.relay_once(
               batch_size: 10_000,
               publish: fn _subject, _body, _opts -> :ok end
             )

    assert transitions(ctx.device_uid) == []
    update_assessment!(ctx.device_uid, cve_id, updated_at: ~N[2026-02-01 00:00:00])
    assert publication(ctx.device_uid, cve_id) == kev_changed
    assert transitions(ctx.device_uid) == []

    update_assessment!(ctx.device_uid, cve_id, source_scope: "container:synthetic")

    assert [scoped] = transitions(ctx.device_uid)
    assert scoped["reason"] == "actionable_attributes_changed"
    assert scoped["changed_fields"] == ["source_scope"]
    assert scoped["transition_seq"] > kev_changed["transition_seq"]
    assert scoped["source_scope"] == "container:synthetic"
    assert scoped["severity"] == "high"
    assert scoped["cvss_score"] == 7.5
    assert scoped["kev"] == true
    assert scoped["installed_version"] == "1.0.0"
    assert scoped["first_exposed_at"] == kev_changed["first_exposed_at"]
    assert scoped["pkg_ord"] == kev_changed["pkg_ord"]
    assert publication(ctx.device_uid, cve_id) == scoped

    update_assessment!(ctx.device_uid, cve_id, source_scope: "container:synthetic")
    assert [^scoped] = transitions(ctx.device_uid)
    assert publication(ctx.device_uid, cve_id) == scoped

    update_assessment!(ctx.device_uid, "CVE-2024-0002", source_scope: "container:synthetic")
    assert [^scoped] = transitions(ctx.device_uid)
    assert publication(ctx.device_uid, "CVE-2024-0002") == nil
  end

  test "deleting a published key resolves it at a new sequence and records its watermark; re-creating it clears the watermark",
       ctx do
    cve_id = "CVE-2024-0003"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)
    last = last_transition_seq(ctx.device_uid, cve_id)

    Repo.delete_all(
      from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
      prefix: "platform"
    )

    assert [_entered, deleted] = transitions(ctx.device_uid)
    assert deleted["state"] == "resolved"
    assert deleted["reason"] == "assessment_deleted"
    assert deleted["transition_seq"] > last
    assert is_binary(deleted["resolved_at"])

    assert [%{state: "resolved", transition_seq: watermark_seq}] = watermarks(ctx.device_uid)
    assert watermark_seq == deleted["transition_seq"]

    assert %{rows: [[^deleted]]} =
             Repo.query!(
               "SELECT payload FROM platform.exposure_fact_watermarks WHERE device_uid = $1",
               [ctx.device_uid]
             )

    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    assert last_transition_seq(ctx.device_uid, cve_id) > watermark_seq
    assert watermarks(ctx.device_uid) == []
  end

  test "a rolled-back assessment change publishes nothing", ctx do
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               insert_assessment!(ctx, endpoint_package_ref, "CVE-2024-0004")
               assert [_entered] = transitions(ctx.device_uid)
               Repo.rollback(:rolled_back)
             end)

    assert transitions(ctx.device_uid) == []
  end

  test "repair retains rollback safety and uses current source state above the observed warehouse sequence",
       ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    cve = "CVE-2024-0020"
    insert_assessment!(ctx, package, cve)
    original = publication(ctx.device_uid, cve)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               update_assessment!(ctx.device_uid, cve, kev: true)
               assert publication(ctx.device_uid, cve)["kev"]
               Repo.rollback(:rollback)
             end)

    assert publication(ctx.device_uid, cve) == original
    assert transitions(ctx.device_uid) == [original]

    repaired = repair_publication(ctx, cve, original["transition_seq"] + 100)
    assert repaired["transition_seq"] > original["transition_seq"] + 100
    assert repaired["state"] == "active"
    assert repaired["kev"] == false
    assert repaired["pkgver_ord"] == original["pkgver_ord"]
    assert publication(ctx.device_uid, cve) == repaired
    assert transitions(ctx.device_uid) == [original, repaired]
  end

  @tag sandbox: :unboxed
  test "absent-source repair keeps a retained terminal and republishes its facts only at or above its sequence",
       ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    on_exit(fn -> cleanup_source(ctx, package) end)
    cve = "CVE-2024-0024"

    insert_assessment!(ctx, package, cve,
      kev: true,
      exploit_available: true,
      fixed_version: "1.2.0",
      transition_reason: "synthetic-exposure"
    )

    assert [entered] = transitions(ctx.device_uid)

    Repo.delete_all(
      from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
      prefix: "platform"
    )

    assert [^entered, terminal] = transitions(ctx.device_uid)
    assert terminal["state"] == "resolved"
    assert terminal["reason"] == "assessment_deleted"
    assert is_binary(terminal["first_exposed_at"])
    oracle = retained_terminal_oracle(terminal["first_exposed_at"])
    assert retained_terminal_facts(entered) == oracle
    assert retained_terminal_facts(terminal) == oracle

    assert watermark_record(ctx.device_uid, cve) == %{
             transition_seq: terminal["transition_seq"],
             payload: terminal
           }

    assert repair_publication(ctx, cve, terminal["transition_seq"] + 100, true) == terminal
    assert transitions(ctx.device_uid) == [entered, terminal]

    replayed = repair_publication(ctx, cve, terminal["transition_seq"] - 1)
    assert replayed == terminal
    assert replayed["transition_seq"] == terminal["transition_seq"]
    assert replayed["transition_xid"] == terminal["transition_xid"]
    assert watermark_record(ctx.device_uid, cve).payload == terminal
    assert transitions(ctx.device_uid) == [entered, terminal]

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               published = repair_publication(ctx, cve, terminal["transition_seq"])
               assert published["transition_seq"] > terminal["transition_seq"]
               assert published["transition_xid"] != terminal["transition_xid"]
               assert published["reason"] == "snapshot_repair"
               assert retained_terminal_facts(published) == oracle
               Repo.rollback(:rollback)
             end)

    assert watermark_record(ctx.device_uid, cve).payload == terminal
    assert transitions(ctx.device_uid) == [entered, terminal]

    refreshed = repair_publication(ctx, cve, terminal["transition_seq"])
    assert refreshed["state"] == "resolved"
    assert refreshed["reason"] == "snapshot_repair"
    assert refreshed["transition_seq"] > terminal["transition_seq"]
    assert refreshed["transition_xid"] != terminal["transition_xid"]
    assert retained_terminal_facts(refreshed) == oracle
    assert refreshed["device_ord"] == terminal["device_ord"]
    assert refreshed["pkg_ord"] == terminal["pkg_ord"]
    assert refreshed["pkgver_ord"] == terminal["pkgver_ord"]
    assert refreshed["cve_ord"] == terminal["cve_ord"]
    assert refreshed["device_lifecycle_seq"] == terminal["device_lifecycle_seq"]

    assert %{transition_seq: refreshed_seq, payload: stored} =
             watermark_record(ctx.device_uid, cve)

    assert refreshed_seq == refreshed["transition_seq"]
    assert stored == refreshed
    assert terminal in transitions(ctx.device_uid)
    assert refreshed in transitions(ctx.device_uid)

    observed = refreshed["transition_seq"] + 40
    later = repair_publication(ctx, cve, observed)
    assert later["transition_seq"] > observed
    assert later["transition_xid"] != refreshed["transition_xid"]
    assert later["state"] == "resolved"
    assert retained_terminal_facts(later) == oracle
    assert watermark_record(ctx.device_uid, cve).payload == later
    assert terminal in transitions(ctx.device_uid)

    assert repair_publication(ctx, cve, later["transition_seq"] + 100, true) == later

    %{rows: [[legacy_seq]]} =
      Repo.query!(
        """
        INSERT INTO platform.exposure_fact_watermarks
          (device_uid, package_identity_key, cve_id, state, transition_seq, transition_xid)
        VALUES ($1, $2, 'EXAMPLE-NULL-TERMINAL', 'resolved',
          platform.exposure_next_sequence(), pg_current_xact_id())
        RETURNING transition_seq
        """,
        [ctx.device_uid, "pkgkey:examplelib:#{ctx.unique}"]
      )

    legacy = repair_publication(ctx, "EXAMPLE-NULL-TERMINAL", 0)
    assert legacy["state"] == "resolved"
    assert legacy["reason"] == "snapshot_repair"
    assert legacy["transition_seq"] > legacy_seq
    assert legacy["installed_version"] == ""
    assert is_nil(legacy["severity"])
    assert is_nil(legacy["cvss_score"])
    assert is_nil(legacy["first_exposed_at"])
    assert watermark_record(ctx.device_uid, "EXAMPLE-NULL-TERMINAL").payload == legacy
    assert watermark_record(ctx.device_uid, cve).payload == later

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_at = now() WHERE uid = $1", [
      ctx.device_uid
    ])

    assert Enum.any?(transitions(ctx.device_uid), &(&1["event_type"] == "device_retired"))
    fenced = watermark_record(ctx.device_uid, cve)
    assert repair_publication(ctx, cve, fenced.transition_seq + 100, true) == fenced.payload
    assert repair_publication(ctx, cve, fenced.transition_seq - 1) == nil
    assert repair_publication(ctx, cve, fenced.transition_seq) == nil
    assert watermark_record(ctx.device_uid, cve) == fenced

    refute Enum.any?(transitions(ctx.device_uid), fn payload ->
             payload["cve_id"] == cve and payload["transition_seq"] > fenced.transition_seq
           end)
  end

  @tag sandbox: :unboxed
  test "missing-source repair and creation serialize in either order and rollback leaves no watermark",
       ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    on_exit(fn -> cleanup_source(ctx, package) end)
    parent = self()
    cve = "CVE-2024-0021"

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert repair_publication(ctx, cve, 10)["state"] == "resolved"
               Repo.rollback(:rollback)
             end)

    assert watermarks(ctx.device_uid) == []
    assert transitions(ctx.device_uid) == []

    repair =
      Task.async(fn ->
        Repo.transaction(fn ->
          terminal = repair_publication(ctx, cve, 10)
          send(parent, {:terminal, terminal})

          receive do
            :commit -> terminal
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:terminal, terminal}, 5_000
    creator = Task.async(fn -> insert_assessment!(ctx, package, cve) end)
    refute Task.yield(creator, 200)
    send(repair.pid, :commit)
    assert {:ok, ^terminal} = Task.await(repair, 10_000)
    assert :ok = Task.await(creator, 10_000)
    current = publication(ctx.device_uid, cve)
    assert terminal["state"] == "resolved"
    assert terminal["transition_seq"] > 10
    assert current["transition_seq"] > terminal["transition_seq"]
    assert current["state"] == "active"
    assert current["transition_xid"] != terminal["transition_xid"]
    update_assessment!(ctx.device_uid, cve, updated_at: ~N[2026-02-01 00:00:00])
    assert publication(ctx.device_uid, cve) == current
    assert %{rows: [[later_xid]]} = Repo.query!("SELECT pg_current_xact_id()::text")
    assert String.to_integer(later_xid) != current["transition_xid"]
    assert watermarks(ctx.device_uid) == []

    second_cve = "CVE-2024-0022"

    creator =
      Task.async(fn ->
        Repo.transaction(fn ->
          insert_assessment!(ctx, package, second_cve)
          send(parent, :created)

          receive do
            :commit -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :created, 5_000
    repair = Task.async(fn -> repair_publication(ctx, second_cve, 10) end)
    refute Task.yield(repair, 200)
    send(creator.pid, :commit)
    assert {:ok, :ok} = Task.await(creator, 10_000)
    assert %{"state" => "active", "kev" => false} = Task.await(repair, 10_000)
    assert watermarks(ctx.device_uid) == []
  end

  test "preparation replaces a retained missing device ordinal with a new sequenced publication",
       ctx do
    package = insert_endpoint_package!(ctx.unique)
    cve = "EXAMPLE-LATE-ORDINAL"
    insert_assessment!(ctx, package, cve)
    original = publication(ctx.device_uid, cve)
    assert original["device_ord"] == nil
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])

    [[ordinal]] =
      Repo.query!("SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = $1", [
        ctx.device_uid
      ]).rows

    {:ok, job} =
      %{"device_uid" => ctx.device_uid, "stage" => "assessments"}
      |> ExposurePublicationPrepareWorker.new()
      |> Oban.insert()

    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    repaired = publication(ctx.device_uid, cve)
    assert repaired["device_ord"] == ordinal
    assert repaired["transition_seq"] > original["transition_seq"]
    assert repaired["state"] == original["state"]
    assert repaired in transitions(ctx.device_uid)
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert publication(ctx.device_uid, cve) == repaired
  end

  test "preparation commits one bounded page and resumes without republishing it", ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    # Never-published candidates exercise legacy preparation without disabling
    # triggers or manufacturing a retained publication in the fixture.
    for n <- 1..501 do
      insert_assessment!(ctx, package, "EXAMPLE-PREPARE-#{n}",
        assessment: "candidate",
        disposition: "unknown"
      )
    end

    assert transitions(ctx.device_uid) == []
    # The old deletion watermark schema had no payload column. Seed that shape
    # using only invented identifiers; preparation must allocate a fresh event.
    %{rows: [[legacy_seq]]} =
      Repo.query!(
        """
        INSERT INTO platform.exposure_fact_watermarks
          (device_uid, package_identity_key, cve_id, state, transition_seq, transition_xid)
        VALUES ($1, $2, 'EXAMPLE-PREPARE-DELETED', 'resolved',
          platform.exposure_next_sequence(), pg_current_xact_id())
        RETURNING transition_seq
        """,
        [ctx.device_uid, "pkgkey:examplelib:#{ctx.unique}"]
      )

    {:ok, job} =
      %{"device_uid" => ctx.device_uid, "stage" => "assessments"}
      |> ExposurePublicationPrepareWorker.new()
      |> Oban.insert()

    started = System.monotonic_time(:millisecond)
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    elapsed = System.monotonic_time(:millisecond) - started
    first = transitions(ctx.device_uid)
    assert length(first) == 500
    assert Enum.all?(first, &(&1["state"] == "resolved" and &1["reason"] == "snapshot_repair"))
    assert Repo.get!(Oban.Job, job.id).args["cursor"]

    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert [last] = transitions(ctx.device_uid) -- first
    assert last["state"] == "resolved"
    assert last["transition_seq"] > Enum.max_by(first, & &1["transition_seq"])["transition_seq"]
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert [terminal] = transitions(ctx.device_uid) -- (first ++ [last])
    assert terminal["cve_id"] == "EXAMPLE-PREPARE-DELETED"
    assert terminal["state"] == "resolved"
    assert terminal["transition_seq"] > legacy_seq
    assert :ok = ExposurePublicationPrepareWorker.perform(job)
    assert transitions(ctx.device_uid) == first ++ [last, terminal]

    [[bytes]] =
      Repo.query!(
        "SELECT avg(pg_column_size(last_exposure_publication))::int FROM platform.endpoint_vulnerability_assessments WHERE device_uid = $1",
        [ctx.device_uid]
      ).rows

    assert bytes > 0

    IO.puts(
      "Synthetic retained publication average bytes: #{bytes}; 500-row preparation ms: #{elapsed}"
    )
  end

  test "preparation reconstructs a legacy retirement and reports its deferred assessments", ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_at = now() WHERE uid = $1", [
      ctx.device_uid
    ])

    # Model an ordinal tombstoned before lifecycle publication existed.
    Repo.query!(
      """
      UPDATE platform.device_fleet_ordinals SET lifecycle_seq = 0, lifecycle_xid = NULL,
        lifecycle_at = NULL, retired_seq = NULL, retired_xid = NULL, retired_at = NULL
      WHERE uid = $1
      """,
      [ctx.device_uid]
    )

    Repo.query!("DELETE FROM platform.exposure_transition_outbox WHERE device_uid = $1", [
      ctx.device_uid
    ])

    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, "CVE-2024-0023")

    {:ok, job} =
      %{"device_uid" => ctx.device_uid}
      |> ExposurePublicationPrepareWorker.new()
      |> Oban.insert()

    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert [marker] = transitions(ctx.device_uid)
    assert marker["event_type"] == "device_retired"
    assert marker["retired_seq"] == marker["transition_seq"]
    assert marker["retired_seq"] > 0
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert {:snooze, 1} = ExposurePublicationPrepareWorker.perform(job)
    assert Repo.get!(Oban.Job, job.id).args["deferred"] == 1
    assert publication(ctx.device_uid, "CVE-2024-0023") == nil
    assert transitions(ctx.device_uid) == [marker]
  end

  test "raw deletion, repeated retirement and restoration preserve identity and publish fresh current facts",
       ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, "CVE-2024-0010")
    assert [active] = transitions(ctx.device_uid)
    assert active["device_lifecycle_seq"] == 0

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_at = now() WHERE uid = $1", [
      ctx.device_uid
    ])

    assert [^active, retired] = transitions(ctx.device_uid)
    assert retired["event_type"] == "device_retired"
    assert retired["transition_seq"] > active["transition_seq"]

    Repo.query!("UPDATE platform.device_fleet_ordinals SET tombstoned = true WHERE uid = $1", [
      ctx.device_uid
    ])

    update_assessment!(ctx.device_uid, "CVE-2024-0010", kev: true)
    assert [^active, ^retired] = transitions(ctx.device_uid)

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_at = NULL WHERE uid = $1", [
      ctx.device_uid
    ])

    assert [^active, ^retired, restored] = transitions(ctx.device_uid)
    assert restored["event_type"] == "device_restored"
    assert restored["device_ord"] == active["device_ord"]
    assert restored["retired_seq"] == retired["transition_seq"]
    assert restored["transition_seq"] > retired["transition_seq"]

    assert :ok = ExposureDeviceRefreshWorker.perform(%Oban.Job{})
    assert [^active, ^retired, ^restored, refreshed] = transitions(ctx.device_uid)
    assert refreshed["device_lifecycle_seq"] == restored["transition_seq"]
    assert refreshed["transition_seq"] > restored["transition_seq"]
    assert refreshed["state"] == "active"
    assert refreshed["kev"] == true
    assert :ok = ExposureDeviceRefreshWorker.perform(%Oban.Job{})
    assert [^active, ^retired, ^restored, ^refreshed] = transitions(ctx.device_uid)

    parent = self()

    publish = fn _subject, body, _opts ->
      event = Jason.decode!(body)

      if event["device_uid"] == ctx.device_uid,
        do: send(parent, {:relayed, event["transition_seq"]})

      if event["transition_seq"] == restored["transition_seq"], do: {:error, :timeout}, else: :ok
    end

    assert {:ok, %{failed: 1}} =
             ExposureTransitionRelay.relay_once(
               batch_size: 10_000,
               publish: publish,
               ensure_stream: fn _ -> :ok end
             )

    fresh_seq = refreshed["transition_seq"]
    refute_received {:relayed, ^fresh_seq}

    acknowledged = fn _subject, body, _opts ->
      event = Jason.decode!(body)

      if event["device_uid"] == ctx.device_uid,
        do: send(parent, {:relayed, event["transition_seq"]})

      :ok
    end

    assert {:ok, %{failed: 0}} =
             ExposureTransitionRelay.relay_once(batch_size: 10_000, publish: acknowledged)

    refute_received {:relayed, ^fresh_seq}

    assert {:ok, %{failed: 0}} =
             ExposureTransitionRelay.relay_once(batch_size: 10_000, publish: acknowledged)

    assert_received {:relayed, ^fresh_seq}
  end

  test "a rolled-back direct ordinal retirement leaves no marker or retirement watermark", ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               Repo.query!(
                 "UPDATE platform.device_fleet_ordinals SET tombstoned = true WHERE uid = $1",
                 [ctx.device_uid]
               )

               assert [%{"event_type" => "device_retired"}] = transitions(ctx.device_uid)
               Repo.rollback(:rollback)
             end)

    assert transitions(ctx.device_uid) == []

    assert %{rows: [[false, 0, nil]]} =
             Repo.query!(
               "SELECT tombstoned, lifecycle_seq, retired_seq FROM platform.device_fleet_ordinals WHERE uid = $1",
               [ctx.device_uid]
             )
  end

  @tag sandbox: :unboxed
  test "retirement waits for an earlier fact publication in another transaction", ctx do
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, "CVE-2024-0011")

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.endpoint_vulnerability_assessments WHERE device_uid = $1",
        [ctx.device_uid]
      )

      TestSupport.delete_device_fixtures!([ctx.device_uid])
      ExposureTransitionCleanup.delete_for_devices!([ctx.device_uid])

      Repo.query!("DELETE FROM platform.endpoint_packages WHERE id = $1", [
        Ecto.UUID.dump!(package)
      ])
    end)

    parent = self()

    publisher =
      Task.async(fn ->
        Repo.transaction(fn ->
          update_assessment!(ctx.device_uid, "CVE-2024-0011", kev: true)
          send(parent, :fact_published)

          receive do
            :commit -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :fact_published, 5_000

    retire =
      Task.async(fn ->
        Repo.query!(
          "UPDATE platform.device_fleet_ordinals SET tombstoned = true WHERE uid = $1",
          [ctx.device_uid]
        )
      end)

    refute Task.yield(retire, 200)
    send(publisher.pid, :commit)
    assert {:ok, :ok} = Task.await(publisher, 10_000)
    assert %{num_rows: 1} = Task.await(retire, 10_000)
    assert [_entered, changed, retired] = transitions(ctx.device_uid)
    assert retired["transition_seq"] > changed["transition_seq"]
  end

  @tag sandbox: :unboxed
  @tag :tmp_dir
  test "replica deliveries recover retained input before a later lifecycle when the original stream is unavailable",
       ctx do
    first = delivery_message(ctx, ctx.unique * 10)
    second = delivery_message(ctx, ctx.unique * 10 + 1)
    bucket = :erlang.phash2(ctx.device_uid, 16)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1 AND stream_sequences <@ $2::bigint[]",
        [bucket, [ctx.unique * 10, ctx.unique * 10 + 1]]
      )
    end)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      parent = self()

      owner =
        Task.async(fn ->
          ExposureDelivery.run([first], fn [_message], locked ->
            :ok = locked.()
            send(parent, :warehouse_load_started)

            receive do
              :uncertain -> {:error, :load_uncertain}
            after
              10_000 -> {:error, :timeout}
            end
          end)
        end)

      assert_receive :warehouse_load_started, 5_000

      assert {:error, :exposure_delivery_busy} =
               ExposureDelivery.run([second], fn _, _ ->
                 flunk("retirement overtook an in-flight load")
               end)

      send(owner.pid, :uncertain)
      assert {:error, :load_uncertain} = Task.await(owner)

      assert [["applying"]] =
               Repo.query!(
                 "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows

      assert %{"error" => %{"code" => 404}} =
               ExposureBroker.request(conn, "$JS.API.STREAM.INFO.EXPOSURE_TRANSITIONS", %{})

      assert {:ok, 1} =
               ExposureDelivery.run([second], fn [message], locked ->
                 :ok = locked.()
                 send(parent, {:delivered, message.data})
                 {:ok, 1}
               end)

      assert_receive {:delivered, first_data}
      assert_receive {:delivered, second_data}
      assert first_data == first.data
      assert second_data == second.data

      assert [] =
               Repo.query!(
                 "SELECT bucket FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows

      assert %{"state" => %{"messages" => 0}} =
               ExposureBroker.request(conn, "$JS.API.STREAM.INFO.EXPOSURE_RECOVERY", %{})
    end)
  end

  @tag :tmp_dir
  test "an interrupted snapshot plan settles before a later live owner replays retained delivery",
       ctx do
    snapshot_http!()
    Repo.query!("INSERT INTO platform.ocsf_devices(uid) VALUES ($1)", [ctx.device_uid])
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, "EXAMPLE-SNAPSHOT-OWNER")
    payload = publication(ctx.device_uid, "EXAMPLE-SNAPSHOT-OWNER")
    parent = self()

    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      stalled = stall_applying_snapshot!(ctx, payload)
      retained = plant_applying_delivery!(ctx, stalled.bucket, ctx.unique * 10)
      successor = delivery_message(ctx, ctx.unique * 10 + 1)

      owner =
        Task.async(fn ->
          ExposureDelivery.run([successor], fn [message], _locked ->
            send(parent, {:owner, message.data})
            {:ok, 1}
          end)
        end)

      assert_receive {:load, http, _path, _headers, [row]}, 5_000
      assert row["snapshot_generation"] == stalled.id
      refute_received {:owner, _}
      send(http, :commit)
      # After the commit the owner settles the plan, replays the retained batch,
      # then journals, retains and applies the successor: a dozen or more
      # sequential CNPG and JetStream round trips. Wait for the owner, not a
      # mailbox deadline; its messages arrive in send order, before its reply.
      assert {:ok, 1} = Task.await(owner, 10_000)
      assert_received {:owner, recovered}
      assert recovered == retained.data
      assert_received {:owner, delivered}
      assert delivered == successor.data
      assert {:ok, settled} = ExposureSnapshotState.get(stalled.id)
      assert settled["pending"][stalled.lane]["state"] == "settled"

      {:ok, :ok} =
        ExposureSnapshotState.change(stalled.id, fn current ->
          next = current |> Map.put("status", "aborted") |> Map.put("pending", %{})
          {:ok, next, :ok}
        end)

      Repo.query!("DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1", [
        stalled.bucket
      ])

      again = stall_applying_snapshot!(ctx, payload)
      _retained = plant_applying_delivery!(ctx, again.bucket, ctx.unique * 10 + 2)

      lane_owner =
        Task.async(fn ->
          ExposureDelivery.with_lane(again.bucket, fn _locked ->
            send(parent, :live_write)
            :ok
          end)
        end)

      assert_receive {:load, http, _path, _headers, [row]}, 5_000
      assert row["snapshot_generation"] == again.id
      refute_received :live_write
      send(http, :commit)
      assert {:error, :invalid_exposure_transition} = Task.await(lane_owner, 10_000)
      refute_received :live_write
      assert {:ok, lane_settled} = ExposureSnapshotState.get(again.id)
      assert lane_settled["pending"][again.lane]["state"] == "settled"
    end)
  end

  @tag :tmp_dir
  test "a completed delivery resumes cleanup without reapplying the batch", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      first = delivery_message(ctx, ctx.unique * 10)
      second = delivery_message(ctx, ctx.unique * 10 + 1)
      bucket = :erlang.phash2(ctx.device_uid, 16)

      assert {:error, _} =
               ExposureDelivery.run([first], fn _, _ ->
                 Gnat.stop(conn)
                 {:ok, 1}
               end)

      assert [["complete", position]] =
               Repo.query!(
                 "SELECT phase, recovery_position FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [
                   bucket
                 ]
               ).rows

      conn = ExposureBroker.connect(port)
      # Simulate a second interruption after deleting the input but before
      # removing the completed journal. Cleanup must be idempotent too.
      assert %{"success" => true} =
               ExposureBroker.request(conn, "$JS.API.STREAM.MSG.DELETE.EXPOSURE_RECOVERY", %{
                 seq: position
               })

      assert {:ok, 1} =
               ExposureDelivery.run([second], fn [message], _ ->
                 assert message.data == second.data
                 {:ok, 1}
               end)

      assert [] =
               Repo.query!(
                 "SELECT bucket FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows
    end)
  end

  @tag :tmp_dir
  test "capture issues no warehouse write and only confirmed missing input requests a snapshot",
       ctx do
    snapshot_http!()

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)
      Gnat.stop(conn)
      ingest = fn _, _ -> flunk("unretained batch reached the warehouse") end
      assert {:error, _} = ExposureDelivery.run([message], ingest)
      assert {:error, _} = ExposureDelivery.run([message], ingest)

      assert [["capturing"]] =
               Repo.query!(
                 "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows

      ExposureBroker.connect(port)

      assert {:error, {:exposure_snapshot_required, ^bucket}} =
               ExposureDelivery.run([message], ingest)

      assert [["snapshot_required"]] =
               Repo.query!(
                 "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows

      assert :ok = ExposureSnapshotMaintenanceWorker.perform(%Oban.Job{})

      [job] =
        Repo.all(
          from(j in Oban.Job,
            where: j.worker == "ServiceRadar.Inventory.ExposureSnapshotWorker"
          )
        )

      assert job.args == %{}
      assert :ok = ExposureSnapshotMaintenanceWorker.perform(%Oban.Job{})
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 1
    end)
  end

  @tag :tmp_dir
  test "an unavailable legacy batch stays blocked rather than being classified as unstarted",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)

      Repo.query!(
        "INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences) VALUES ($1, $2)",
        [
          bucket,
          [ctx.unique * 10 - 1]
        ]
      )

      assert {:error, {:exposure_recovery_message_unavailable, _}} =
               ExposureDelivery.run([message], fn _, _ ->
                 flunk("legacy journal was bypassed")
               end)

      assert [["legacy"]] =
               Repo.query!(
                 "SELECT phase FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               ).rows
    end)
  end

  @tag :tmp_dir
  test "a future lifecycle retry releases delivery ownership for the missing marker", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)

      assert {:error, :exposure_lifecycle_pending} =
               ExposureDelivery.run([message], fn _, _ ->
                 {:retry, :exposure_lifecycle_pending}
               end)

      assert {:ok, 1} = ExposureDelivery.run([message], fn _, _ -> {:ok, 1} end)
    end)
  end

  @tag :tmp_dir
  test "a blocked bucket does not starve independent delivery buckets", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      first = delivery_message(ctx, ctx.unique * 10)

      second =
        Enum.find_value(1..32, fn suffix ->
          message =
            delivery_message(
              %{ctx | device_uid: "#{ctx.device_uid}-#{suffix}"},
              ctx.unique * 10 + 1
            )

          if message.metadata.subject != first.metadata.subject, do: message
        end)

      parent = self()

      assert {:error, :exposure_lifecycle_pending} =
               ExposureDelivery.run([first, second], fn [message], _ ->
                 if message.data == first.data do
                   {:retry, :exposure_lifecycle_pending}
                 else
                   send(parent, {:accepted, message.data})
                   {:ok, 1}
                 end
               end)

      assert_receive {:accepted, data}
      assert data == second.data
    end)
  end

  @tag :tmp_dir
  test "one session owns the bucket for the whole delivery, and stranded legacy locks do not block it",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)

      # A pooled server connection that kept the pre-fix bucket lock after its
      # unlock ran on a different backend.
      stranded = start_supervised!({Postgrex, DirectSession.connection_opts()})
      Postgrex.query!(stranded, "SELECT pg_advisory_lock(74523, $1)", [bucket])

      parent = self()

      assert {:ok, 1} =
               ExposureDelivery.run([message], fn [_message], locked ->
                 # Ownership checks run on the session that holds the lock.
                 :ok = locked.()
                 send(parent, {:holders, delivery_lock_holders(bucket)})
                 {:ok, 1}
               end)

      assert_received {:holders, [[_session]]}
      assert delivery_lock_holders(bucket) == []
    end)
  end

  @tag :tmp_dir
  test "a delivery whose lock session ends fails closed with an error and keeps its journal",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)

      assert {:error, :exposure_delivery_ownership_lost} =
               ExposureDelivery.run([message], fn [_message], locked ->
                 :ok = locked.()
                 [[session]] = delivery_lock_holders(bucket)
                 Repo.query!("SELECT pg_terminate_backend($1::int, 5000)", [session])
                 # The load itself succeeded; only the ownership check stands
                 # between it and retiring the journal entry.
                 {:ok, 1}
               end)

      assert %{rows: [[[sequence]]]} =
               Repo.query!(
                 "SELECT stream_sequences FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               )

      assert sequence == ctx.unique * 10
    end)
  end

  @tag :tmp_dir
  test "finishing a delivery leaves another owner's journal row for the same bucket", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)
      own = [ctx.unique * 10]
      foreign = [ctx.unique * 10 + 1]

      assert {:ok, 1} =
               ExposureDelivery.run([message], fn [_message], locked ->
                 :ok = locked.()

                 assert %{num_rows: 1} =
                          Repo.query!(
                            """
                            UPDATE platform.exposure_delivery_batches
                            SET stream_sequences = $2::bigint[]
                            WHERE bucket = $1 AND stream_sequences = $3::bigint[]
                            """,
                            [bucket, foreign, own]
                          )

                 {:ok, 1}
               end)

      assert %{rows: [[^foreign]]} =
               Repo.query!(
                 "SELECT stream_sequences FROM platform.exposure_delivery_batches WHERE bucket = $1",
                 [bucket]
               )
    end)
  end

  @tag :tmp_dir
  test "finishing a delivery preserves a replacement operation with identical source positions",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn _conn, _port ->
      message = delivery_message(ctx, ctx.unique * 10)
      bucket = :erlang.phash2(ctx.device_uid, 16)
      own = [ctx.unique * 10]
      foreign = Ecto.UUID.generate()

      assert {:ok, 1} =
               ExposureDelivery.run([message], fn [_message], locked ->
                 :ok = locked.()

                 {:ok, body, hash} =
                   ExposureRecovery.encode(bucket, foreign, [{ctx.unique * 10, message}])

                 {:ok, position} = ExposureRecovery.retain(bucket, foreign, body, hash)

                 assert %{num_rows: 1} =
                          Repo.query!(
                            """
                            UPDATE platform.exposure_delivery_batches
                            SET operation_id = $2::text::uuid, payload_hash = $3,
                                recovery_position = $4
                            WHERE bucket = $1 AND stream_sequences = $5::bigint[]
                            """,
                            [bucket, foreign, hash, position, own]
                          )

                 send(self(), {:replacement_position, position})
                 {:ok, 1}
               end)

      assert_received {:replacement_position, position}

      assert %{rows: [[^foreign, "applying", ^position]]} =
               Repo.query!(
                 """
                 SELECT operation_id::text, phase, recovery_position
                 FROM platform.exposure_delivery_batches WHERE bucket = $1
                 """,
                 [bucket]
               )
    end)
  end

  # Exclusive (not access exclusive) lets the empty journal read through and
  # holds the insert until another owner commits the bucket row.
  @tag sandbox: :unboxed
  test "a journal row committed while this insert waits is busy and is not loaded", ctx do
    message = delivery_message(ctx, ctx.unique * 10)
    bucket = :erlang.phash2(ctx.device_uid, 16)
    foreign = [ctx.unique * 10 + 1]
    parent = self()

    holder = start_supervised!({Postgrex, DirectSession.connection_opts()})

    on_exit(fn ->
      try do
        Postgrex.query(holder, "ROLLBACK", [])
      catch
        :exit, _ -> :ok
      end

      Repo.query!(
        """
        DELETE FROM platform.exposure_delivery_batches
        WHERE bucket = $1 AND stream_sequences = $2::bigint[]
        """,
        [bucket, foreign]
      )
    end)

    Postgrex.query!(holder, "BEGIN", [])
    Postgrex.query!(holder, "SET LOCAL lock_timeout = '5s'", [])

    Postgrex.query!(
      holder,
      "LOCK TABLE platform.exposure_delivery_batches IN EXCLUSIVE MODE",
      []
    )

    delivery =
      Task.async(fn ->
        ExposureDelivery.run([message], fn _, _ ->
          send(parent, :loaded)
          {:ok, 1}
        end)
      end)

    assert await_journal_insert_waiter!()

    Postgrex.query!(
      holder,
      """
      INSERT INTO platform.exposure_delivery_batches(bucket, stream_sequences)
      VALUES ($1, $2::bigint[])
      """,
      [bucket, foreign]
    )

    Postgrex.query!(holder, "COMMIT", [])

    assert {:error, :exposure_delivery_busy} = Task.await(delivery, 10_000)
    refute_received :loaded

    assert %{rows: [[^foreign]]} =
             Repo.query!(
               "SELECT stream_sequences FROM platform.exposure_delivery_batches WHERE bucket = $1",
               [bucket]
             )
  end

  defp await_journal_insert_waiter!(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    waiting? =
      Repo.query!("""
      SELECT 1 FROM pg_locks
      WHERE relation = 'platform.exposure_delivery_batches'::regclass
        AND NOT granted
        AND mode = 'RowExclusiveLock'
      """).rows != []

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("delivery insert did not wait on the journal table")

      true ->
        Process.sleep(20)
        await_journal_insert_waiter!(deadline)
    end
  end

  defp delivery_lock_holders(bucket) do
    Repo.query!(
      """
      SELECT pid FROM pg_locks
      WHERE locktype = 'advisory' AND granted
        AND classid = 74525 AND objid = $1 AND objsubid = 2
      """,
      [bucket]
    ).rows
  end

  defp delivery_message(ctx, seq) do
    %{
      data: Jason.encode!(%{device_uid: ctx.device_uid, transition_seq: seq}),
      metadata: %{
        subject: ExposureTransitionRelay.subject(ctx.device_uid),
        jetstream_ack: %{stream: "EXPOSURE_TRANSITIONS", stream_sequence: seq}
      }
    }
  end

  test "CVE ordinals are deterministic for canonical identifiers and dictionary-backed above 10^12 otherwise" do
    ordinal = fn id ->
      %{rows: [[value]]} = Repo.query!("SELECT platform.exposure_cve_ordinal($1)", [id])
      value
    end

    assert ordinal.("CVE-2024-0001") == 20_240_000_001
    assert ordinal.("CVE-2024-1234567") == 20_241_234_567

    # An eight-digit sequence, a non-canonical leading zero and a non-CVE id
    # each get their own stable dictionary ordinal.
    for id <- ["CVE-2024-12345678", "CVE-2024-012345", "GHSA-0000-0000-0001"] do
      assert ordinal.(id) >= 1_000_000_000_000
      assert ordinal.(id) == ordinal.(id)
    end

    assert ordinal.("CVE-2024-012345") != ordinal.("CVE-2024-12345678")
  end

  # Two transactions change one assessment. The second waits on the first's row
  # lock, so it draws its sequence after the first commits.
  @tag sandbox: :unboxed
  test "concurrent changes to one assessment are sequenced in commit order", ctx do
    cve_id = "CVE-2024-0005"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    on_exit(fn ->
      Repo.delete_all(
        from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
        prefix: "platform"
      )

      ExposureTransitionCleanup.delete_for_devices!([ctx.device_uid])

      Repo.delete_all(
        from(p in "endpoint_packages", where: p.id == ^Ecto.UUID.dump!(endpoint_package_ref)),
        prefix: "platform"
      )
    end)

    parent = self()

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          update_assessment!(ctx.device_uid, cve_id, cvss_score: 8.1)
          send(parent, :first_locked)

          receive do
            :commit -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :first_locked, 5_000

    second =
      Task.async(fn ->
        Repo.transaction(fn -> update_assessment!(ctx.device_uid, cve_id, kev: true) end)
      end)

    # The second update is blocked on the row lock until the first commits.
    refute Task.yield(second, 300)
    send(first.pid, :commit)
    assert {:ok, :ok} = Task.await(first, 10_000)
    assert {:ok, :ok} = Task.await(second, 10_000)

    assert [_entered, cvss, kev] = transitions(ctx.device_uid)
    assert cvss["changed_fields"] == ["cvss_score"]
    assert kev["changed_fields"] == ["kev"]
    assert kev["transition_seq"] > cvss["transition_seq"]
    # The later commit's after-image already includes the earlier change.
    assert kev["cvss_score"] == 8.1
  end

  test "dimension publication rolls back with its source and describes changed versions without duplicate writes",
       ctx do
    cve_id = "EXAMPLE-DIM-#{ctx.unique}"
    package = insert_endpoint_package!(ctx.unique)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               insert_assessment!(ctx, package, cve_id)
               assert length(dimension_messages(ctx, cve_id)) == 2
               Repo.rollback(:rollback)
             end)

    assert dimension_messages(ctx, cve_id) == []

    insert_assessment!(ctx, package, cve_id)
    [cve, first] = dimension_messages(ctx, cve_id)
    assert cve["cve_id"] == cve_id
    assert cve["epss_score"] == nil
    assert first["package_name"] == "examplelib"
    fact_seq = last_transition_seq(ctx.device_uid, cve_id)
    update_assessment!(ctx.device_uid, cve_id, package_name: "renamed-examplelib")
    assert last_transition_seq(ctx.device_uid, cve_id) == fact_seq
    [^cve, ^first, renamed] = dimension_messages(ctx, cve_id)
    assert renamed["package_name"] == "renamed-examplelib"
    assert renamed["transition_seq"] > first["transition_seq"]
    update_assessment!(ctx.device_uid, cve_id, package_name: "renamed-examplelib")
    assert dimension_messages(ctx, cve_id) == [cve, first, renamed]

    update_assessment!(ctx.device_uid, cve_id, installed_version: "2.0.0")
    [^cve, ^first, ^renamed, upgraded] = dimension_messages(ctx, cve_id)
    assert upgraded["pkg_ord"] == first["pkg_ord"]
    refute upgraded["pkgver_ord"] == first["pkgver_ord"]
    assert upgraded["installed_version"] == "2.0.0"

    Repo.delete_all(
      from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
      prefix: "platform"
    )

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.exposure_dimension_state WHERE content->>'package_identity_key' = $1",
               ["pkgkey:examplelib:#{ctx.unique}"]
             )
  end

  test "daily priority refresh changes and clears EPSS without rewriting assessments", ctx do
    cve_id = "EXAMPLE-EPSS-#{ctx.unique}"
    feed = "example-dimension-#{ctx.unique}"
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, cve_id)
    original = transitions(ctx.device_uid)

    Repo.insert_all(
      "vulnerability_feed_definitions",
      [
        %{
          provider: "example",
          feed_key: feed,
          display_name: "Synthetic dimension feed",
          feed_type: "kev",
          enabled: true
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "vulnerability_advisories",
      [
        %{
          provider: "example",
          feed_key: feed,
          source_object_id: cve_id,
          advisory_id: cve_id,
          cve_id: cve_id,
          kev: true,
          current: true,
          metadata: %{"priority" => %{"epss_score" => 0.0}}
        }
      ],
      prefix: "platform"
    )

    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    after_refresh = dimension_messages(ctx, cve_id)
    assert List.last(after_refresh)["epss_score"] == 0.0
    assert transitions(ctx.device_uid) == original
    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    assert dimension_messages(ctx, cve_id) == after_refresh

    # A later fact transition re-registers identity without losing enrichment.
    update_assessment!(ctx.device_uid, cve_id, kev: true)
    assert dimension_messages(ctx, cve_id) == after_refresh

    Repo.update_all(
      from(f in "vulnerability_feed_definitions", where: f.feed_key == ^feed),
      [set: [enabled: false]],
      prefix: "platform"
    )

    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    cleared = List.last(dimension_messages(ctx, cve_id))
    assert Map.has_key?(cleared, "epss_score") and cleared["epss_score"] == nil
    assert cleared["transition_seq"] > List.last(after_refresh)["transition_seq"]
    assert ctx.device_uid |> transitions() |> length() == 2
  end

  test "dimension relay retains the exact failed publication until PubAck", ctx do
    cve_id = "EXAMPLE-RELAY-#{ctx.unique}"
    insert_assessment!(ctx, insert_endpoint_package!(ctx.unique), cve_id)
    [expected_cve, expected_package] = dimension_messages(ctx, cve_id)
    parent = self()

    publish = fn subject, body, opts ->
      payload = Jason.decode!(body)

      if payload in [expected_cve, expected_package],
        do: send(parent, {:dimension, subject, payload, opts[:msg_id]})

      if payload == expected_package, do: {:error, :timeout}, else: :ok
    end

    assert {:ok, %{failed: 1}} =
             ExposureDimensionRelay.relay_once(
               batch_size: 100_000,
               publish: publish,
               ensure_stream: fn _ -> :ok end
             )

    assert_received {:dimension, "exposure.dimensions.cve", ^expected_cve, cve_msg_id}
    assert_received {:dimension, "exposure.dimensions.package", ^expected_package, package_msg_id}
    assert cve_msg_id == "exposure-dimension-#{expected_cve["transition_seq"]}"
    assert package_msg_id == "exposure-dimension-#{expected_package["transition_seq"]}"
    assert dimension_messages(ctx, cve_id) == [expected_package]

    assert {:ok, %{failed: 0}} =
             ExposureDimensionRelay.relay_once(
               publish: fn subject, body, opts ->
                 send(parent, {:retried, subject, Jason.decode!(body), opts[:msg_id]})
                 :ok
               end
             )

    assert_received {:retried, "exposure.dimensions.package", ^expected_package, ^package_msg_id}
    assert dimension_messages(ctx, cve_id) == []
  end

  @tag sandbox: :unboxed
  test "dimension creation and equal-content races serialize before allocating sequences", ctx do
    for {offset, initial, first_score, final_score} <- [{0, nil, 0.1, 0.9}, {1, 0.1, 0.9, 0.1}] do
      ordinal = 2_000_000_000_000 + ctx.unique * 2 + offset

      content = %{
        "cve_ord" => ordinal,
        "cve_id" => "EXAMPLE-CONCURRENT-#{ordinal}",
        "epss_score" => initial
      }

      on_exit(fn ->
        for table <- ["exposure_dimension_outbox", "exposure_dimension_state"] do
          Repo.delete_all(
            from(row in table, where: row.kind == "cve" and row.ordinal == ^ordinal),
            prefix: "platform"
          )
        end
      end)

      if initial do
        Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
          ordinal,
          content
        ])
      end

      parent = self()

      first =
        Task.async(fn ->
          Repo.transaction(fn ->
            %{rows: [[seq]]} =
              Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
                ordinal,
                %{content | "epss_score" => first_score}
              ])

            send(parent, {:created, seq})

            receive do
              :commit -> seq
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:created, first_seq}, 5_000

      second =
        Task.async(fn ->
          Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
            ordinal,
            %{content | "epss_score" => final_score}
          ])
        end)

      refute Task.yield(second, 300)
      send(first.pid, :commit)
      assert {:ok, ^first_seq} = Task.await(first, 10_000)
      assert %{rows: [[second_seq]]} = Task.await(second, 10_000)
      assert second_seq > first_seq

      assert %{rows: [[^final_score]]} =
               Repo.query!(
                 "SELECT (content->>'epss_score')::float8 FROM platform.exposure_dimension_state WHERE kind = 'cve' AND ordinal = $1",
                 [ordinal]
               )
    end
  end

  defp dimension_messages(ctx, cve_id) do
    key = "pkgkey:examplelib:#{ctx.unique}"

    Repo.all(
      from(o in "exposure_dimension_outbox",
        where:
          fragment("?->>'package_identity_key'", o.payload) == ^key or
            fragment("?->>'cve_id'", o.payload) == ^cve_id,
        order_by: [asc: o.id],
        select: o.payload
      ),
      prefix: "platform"
    )
  end

  defp insert_endpoint_package!(unique) do
    endpoint_package_ref = Ecto.UUID.generate()

    Repo.insert_all(
      "endpoint_packages",
      [
        %{
          id: Ecto.UUID.dump!(endpoint_package_ref),
          coordinate_key: "exposure-transition-#{unique}",
          cpes: [],
          package_manager: "dpkg",
          name: "examplelib",
          version: "1.0.0",
          source_scope: "host",
          metadata: %{}
        }
      ],
      prefix: "platform"
    )

    endpoint_package_ref
  end

  defp insert_assessment!(ctx, endpoint_package_ref, cve_id, attrs \\ []) do
    now = ~N[2026-01-01 00:00:00]

    row =
      Map.merge(
        %{
          device_uid: ctx.device_uid,
          package_identity_key: "pkgkey:examplelib:#{ctx.unique}",
          source_scope: "host",
          endpoint_package_ref: Ecto.UUID.dump!(endpoint_package_ref),
          cve_id: cve_id,
          status: "active",
          assessment: "confirmed",
          disposition: "affected",
          applicability_reason: "synthetic",
          freshness: "fresh",
          package_name: "examplelib",
          installed_version: "1.0.0",
          severity: "high",
          cvss_score: 7.5,
          supporting_match_ids: [],
          supporting_assertion_ids: [],
          evidence: %{},
          metadata: %{},
          first_seen_at: now,
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        },
        Map.new(attrs)
      )

    Repo.insert_all("endpoint_vulnerability_assessments", [row], prefix: "platform")
    :ok
  end

  defp update_assessment!(device_uid, cve_id, set) do
    {1, _} =
      Repo.update_all(
        from(a in "endpoint_vulnerability_assessments",
          where: a.device_uid == ^device_uid and a.cve_id == ^cve_id
        ),
        [set: set],
        prefix: "platform"
      )

    :ok
  end

  defp publication(uid, cve) do
    Repo.one(
      from(a in "endpoint_vulnerability_assessments",
        where: a.device_uid == ^uid and a.cve_id == ^cve,
        select: a.last_exposure_publication
      ),
      prefix: "platform"
    )
  end

  defp repair_publication(ctx, cve, observed, missing_only \\ false) do
    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT platform.exposure_repair_publication($1, $2, $3, $4, $5)",
        [ctx.device_uid, "pkgkey:examplelib:#{ctx.unique}", cve, observed, missing_only]
      )

    payload
  end

  defp retained_terminal_facts(payload) do
    Map.take(payload, [
      "installed_version",
      "severity",
      "cvss_score",
      "kev",
      "exploit_available",
      "fixed_version",
      "fix_available",
      "source_scope",
      "first_exposed_at",
      "assessment_status",
      "assessment",
      "disposition",
      "assessment_transition_reason"
    ])
  end

  defp retained_terminal_oracle(first_exposed_at) do
    %{
      "installed_version" => "1.0.0",
      "severity" => "high",
      "cvss_score" => 7.5,
      "kev" => true,
      "exploit_available" => true,
      "fixed_version" => "1.2.0",
      "fix_available" => true,
      "source_scope" => "host",
      "first_exposed_at" => first_exposed_at,
      "assessment_status" => "active",
      "assessment" => "confirmed",
      "disposition" => "affected",
      "assessment_transition_reason" => "synthetic-exposure"
    }
  end

  defp watermark_record(device_uid, cve) do
    case Repo.query!(
           """
           SELECT transition_seq, payload
           FROM platform.exposure_fact_watermarks
           WHERE device_uid = $1 AND cve_id = $2
           """,
           [device_uid, cve]
         ).rows do
      [[seq, payload]] -> %{transition_seq: seq, payload: payload}
      [] -> nil
    end
  end

  defp cleanup_source(ctx, package) do
    Repo.query!("DELETE FROM platform.endpoint_vulnerability_assessments WHERE device_uid = $1", [
      ctx.device_uid
    ])

    TestSupport.delete_device_fixtures!([ctx.device_uid])
    ExposureTransitionCleanup.delete_for_devices!([ctx.device_uid])

    Repo.query!("DELETE FROM platform.endpoint_packages WHERE id = $1", [Ecto.UUID.dump!(package)])
  end

  defp last_transition_seq(device_uid, cve_id) do
    Repo.one(
      from(a in "endpoint_vulnerability_assessments",
        where: a.device_uid == ^device_uid and a.cve_id == ^cve_id,
        select: a.last_transition_seq
      ),
      prefix: "platform"
    )
  end

  defp transitions(device_uid) do
    Repo.all(
      from(o in "exposure_transition_outbox",
        where: o.device_uid == ^device_uid,
        order_by: [asc: o.id],
        select: o.payload
      ),
      prefix: "platform"
    )
  end

  defp watermarks(device_uid) do
    Repo.all(
      from(w in "exposure_fact_watermarks",
        where: w.device_uid == ^device_uid,
        select: %{state: w.state, transition_seq: w.transition_seq}
      ),
      prefix: "platform"
    )
  end
end
