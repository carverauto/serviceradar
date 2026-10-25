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

  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.Inventory.ExposureDeviceRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRelay
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession
  alias ServiceRadar.TestSupport
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
  test "replica deliveries serialize and an uncertain load is replayed before a later lifecycle",
       ctx do
    start_recovery_broker!()
    first = delivery_message(ctx, ctx.unique * 10)
    second = delivery_message(ctx, ctx.unique * 10 + 1)
    bucket = :erlang.phash2(ctx.device_uid, 16)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.exposure_delivery_batches WHERE bucket = $1 AND stream_sequences <@ $2::bigint[]",
        [bucket, [ctx.unique * 10, ctx.unique * 10 + 1]]
      )
    end)

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

    missing =
      Task.async(fn ->
        ExposureDelivery.run([second], fn _, _ ->
          flunk("missing recovery input was ignored")
        end)
      end)

    assert_receive {:recovery_request, broker, "$JS.API.STREAM.MSG.GET.EXPOSURE_TRANSITIONS",
                    request},
                   2_000

    assert request == %{"seq" => ctx.unique * 10}
    send(broker, {:respond, %{error: %{code: 404}}})
    assert {:error, {:exposure_recovery_message_unavailable, _}} = Task.await(missing)

    ingest = fn [message], locked ->
      :ok = locked.()
      send(parent, {:delivered, message.data})
      {:ok, 1}
    end

    recovered = Task.async(fn -> ExposureDelivery.run([second], ingest) end)

    assert_receive {:recovery_request, broker, "$JS.API.STREAM.MSG.GET.EXPOSURE_TRANSITIONS",
                    request},
                   2_000

    assert request == %{"seq" => ctx.unique * 10}

    send(
      broker,
      {:respond,
       %{
         message: %{
           seq: ctx.unique * 10,
           subject: first.metadata.subject,
           data: Base.encode64(first.data)
         }
       }}
    )

    assert {:ok, 1} = Task.await(recovered)
    assert_receive {:delivered, first_data}
    assert_receive {:delivered, second_data}
    assert first_data == first.data
    assert second_data == second.data

    assert %{rows: []} =
             Repo.query!(
               "SELECT bucket FROM platform.exposure_delivery_batches WHERE bucket = $1",
               [bucket]
             )
  end

  test "a future lifecycle retry releases delivery ownership for the missing marker", ctx do
    message = delivery_message(ctx, ctx.unique * 10)

    assert {:error, :exposure_lifecycle_pending} =
             ExposureDelivery.run([message], fn _, _ -> {:retry, :exposure_lifecycle_pending} end)

    assert {:ok, 1} =
             ExposureDelivery.run([message], fn _, _ -> {:ok, 1} end)
  end

  test "one session owns the bucket for the whole delivery, and stranded legacy locks do not block it",
       ctx do
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
  end

  test "a delivery whose lock session ends fails closed with an error and keeps its journal",
       ctx do
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
  end

  test "a blocked bucket does not starve independent delivery buckets", ctx do
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
  end

  # A protocol fixture for the external stream API. Production Gnat handles the
  # request, subscription and response decoding; recovery has no test-only hook.
  defp start_recovery_broker! do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)

         :ok =
           :gen_tcp.send(
             socket,
             ~s(INFO {"server_id":"synthetic-exposure-broker","headers":false}\r\n)
           )

         recovery_commands(socket, owner, %{})
       end}
    )

    start_supervised!(%{
      id: :exposure_recovery_gnat,
      start:
        {Gnat, :start_link,
         [
           %{host: "127.0.0.1", port: port},
           [name: ServiceRadar.NATS.Connection.connection_name()]
         ]}
    })
  end

  defp recovery_commands(socket, owner, subscriptions) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        case String.split(String.trim(line)) do
          ["SUB", subject, sid] ->
            recovery_commands(socket, owner, Map.put(subscriptions, subject, sid))

          ["PUB", subject, reply, bytes] ->
            :ok = :inet.setopts(socket, packet: :raw)
            {:ok, payload} = :gen_tcp.recv(socket, String.to_integer(bytes) + 2)
            :ok = :inet.setopts(socket, packet: :line)
            request = payload |> String.trim() |> Jason.decode!()
            send(owner, {:recovery_request, self(), subject, request})

            receive do
              {:respond, response} ->
                body = Jason.encode!(response)

                sid =
                  Enum.find_value(subscriptions, fn {filter, sid} ->
                    if filter == reply or
                         String.starts_with?(reply, String.trim_trailing(filter, "*")),
                       do: sid
                  end)

                :ok =
                  :gen_tcp.send(socket, "MSG #{reply} #{sid} #{byte_size(body)}\r\n#{body}\r\n")
            after
              5_000 -> raise "recovery response was not supplied"
            end

            recovery_commands(socket, owner, subscriptions)

          ["PING"] ->
            :ok = :gen_tcp.send(socket, "PONG\r\n")
            recovery_commands(socket, owner, subscriptions)

          _ ->
            recovery_commands(socket, owner, subscriptions)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp delivery_lock_holders(bucket) do
    Repo.query!(
      """
      SELECT pid FROM pg_locks
      WHERE locktype = 'advisory' AND granted
        AND classid = 74524 AND objid = $1 AND objsubid = 2
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
