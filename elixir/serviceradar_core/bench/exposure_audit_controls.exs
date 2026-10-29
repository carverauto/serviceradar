defmodule ServiceRadar.ExposureAudit.Controls do
  @moduledoc "Behavior controls owned by the manual audit target; all inputs are synthetic."
  import ExUnit.Assertions

  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.ExposureAudit.Prototype
  alias ServiceRadar.ExposureAudit.Readiness
  alias ServiceRadar.ExposureAudit.SQL
  alias ServiceRadar.ExposureAudit.State
  alias ServiceRadar.Inventory.ExposureReadiness

  def verify! do
    publication_validation!()
    run = State.open!()
    assert 2 == State.admit!(run, 0, [1, 2])
    {resumed, 2, false} = State.resume!(run.id)
    assert resumed == run
    Prototype.resume_admission!(run.id)
    Prototype.resume_admission!(run.id)

    assert [[200, 200]] =
             State.query!(
               "SELECT count(*),count(DISTINCT device_ord) FROM platform.exposure_audit_work WHERE run_id=$1::text::uuid",
               [run.id]
             )

    assert Enum.any?(
             Ash.read!(ServiceRadar.ExposureAudit.Run, authorize?: false),
             &(&1.id == run.id)
           )

    assert 52_551 == Prototype.dimensions!(run)
    assert 0 == Prototype.dimensions!(run)
    [first, second] = Prototype.compare!(run, [1, 2])
    assert first.matches and second.matches
    State.record!(run, [first, second])
    batch = Readiness.status_many!([1, 2])

    for ordinal <- [1, 2] do
      assert {:ok, expected} = ExposureReadiness.status(ordinal)
      assert Map.take(expected, [:ready, :reasons]) == batch[ordinal]
    end

    fact_controls!(run)
    shared_source_controls!(run)
    watermark_reference!(run)
    readiness_controls!()
    covering_snapshot!(run, first, second)
    terminal_proof!(run)
    dimension_failure!(run)
    busy_device!(run)
    live_after_images!(run)
    empty_device!(run)

    # Changing a payload at the same sequence must change the generated binding.
    [[payload, hash]] =
      State.query!(
        "SELECT payload,audit_content_hash FROM platform.exposure_dimension_state WHERE kind='package' AND ordinal=1"
      )

    State.query!(
      "UPDATE platform.exposure_dimension_state SET payload=jsonb_set(payload,'{package_name}','\"synthetic changed name\"') WHERE kind='package' AND ordinal=1"
    )

    try do
      [[changed]] =
        State.query!(
          "SELECT audit_content_hash FROM platform.exposure_dimension_state WHERE kind='package' AND ordinal=1"
        )

      refute changed == hash
      [result] = Prototype.compare!(run, [1])
      refute result.matches
      assert result.missing_proofs > 0
    after
      State.query!(
        "UPDATE platform.exposure_dimension_state SET payload=$1 WHERE kind='package' AND ordinal=1",
        [payload]
      )
    end

    # Replay remains independently checked even when warehouse and current source agree.
    [[id, severity]] =
      State.query!(
        "SELECT id::text,severity FROM platform.endpoint_vulnerability_assessments WHERE device_uid='sr:capacity-1' ORDER BY id LIMIT 1"
      )

    source_change!(id, "severity='low'")
    warehouse!("UPDATE exposure_facts SET severity_rank=1 WHERE device_ord=1 AND pkg_ord=1")

    try do
      [result] = Prototype.compare!(run, [1])
      assert result.source == result.warehouse
      assert result.replay_drift == 1
      refute result.matches
    after
      source_change!(id, "severity=$2", [severity])
      warehouse!("UPDATE exposure_facts SET severity_rank=4 WHERE device_ord=1 AND pkg_ord=1")
    end

    # A proof committed after V is invisible in V. The next bounded view sees it.
    State.query!(
      "DELETE FROM platform.exposure_audit_proofs WHERE run_id=$1::text::uuid AND kind='package' AND ordinal=1",
      [run.id]
    )

    [before_proof] =
      Prototype.compare!(run, [1], fn _reader -> assert 1 == Prototype.dimensions!(run) end)

    refute before_proof.matches
    [after_proof] = Prototype.compare!(run, [1])
    assert after_proof.matches
    State.record!(run, [after_proof])

    [[evidence]] =
      State.query!(
        "SELECT checked_at FROM platform.exposure_reconciliation_checks WHERE device_ord=1"
      )

    assert evidence == after_proof.evidence_at
    assert NaiveDateTime.compare(evidence, after_proof.fact_started_at) != :gt

    # No comparison can publish under a prior restore fence.
    State.invalidate!()

    assert_raise ExUnit.AssertionError, ~r/fence changed/, fn ->
      State.record!(run, [after_proof])
    end

    [[^evidence]] =
      State.query!(
        "SELECT checked_at FROM platform.exposure_reconciliation_checks WHERE device_ord=1"
      )

    fresh = State.open!()
    assert 52_551 == Prototype.dimensions!(fresh)

    assert_raise Postgrex.Error, fn ->
      Prototype.compare!(fresh, [1], fn reader ->
        Postgrex.query!(reader, "SET LOCAL statement_timeout='1ms'", [])
        Postgrex.query!(reader, "SELECT pg_sleep(0.02)", [])
      end)
    end

    State.query!(
      "UPDATE platform.exposure_audit_runs SET expires_at=clock_timestamp() AT TIME ZONE 'utc'-interval '1 second' WHERE id=$1::text::uuid",
      [fresh.id]
    )

    assert_raise ExUnit.AssertionError, ~r/expired/, fn -> State.admit!(fresh, 0, [1]) end

    [[control]] =
      State.query!(
        "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord=1"
      )

    State.query!(
      "UPDATE platform.exposure_reconciliation_checks SET control=jsonb_set(control,'{repairs}','[{\"synthetic\":true}]') WHERE device_ord=1"
    )

    State.cleanup!(fresh.id)

    assert [[[%{"synthetic" => true}]]] =
             State.query!(
               "SELECT control->'repairs' FROM platform.exposure_reconciliation_checks WHERE device_ord=1"
             )

    State.query!(
      "UPDATE platform.exposure_reconciliation_checks SET control=$1 WHERE device_ord=1",
      [control]
    )

    assert [[0]] =
             State.query!(
               "SELECT count(*) FROM platform.exposure_audit_work WHERE run_id=$1::text::uuid",
               [run.id]
             )

    assert [[0]] =
             State.query!(
               "SELECT count(*) FROM platform.exposure_audit_proofs WHERE run_id=$1::text::uuid",
               [run.id]
             )

    IO.puts(
      "EXPOSURE_AUDIT_CONTROLS generated_binding replay_drift late_proof evidence_age restore_fence timeout expiry cleanup durable_admission same_count missing_fact terminal_reference new_generation grouped_readiness per_device_failure busy_device concurrent_after_images empty_device warehouse_only duplicate_source malformed_source watermark_reference"
    )
  end

  defp warehouse!(sql), do: SQL.warehouse!(sql)

  defp fact_controls!(run) do
    warehouse!("UPDATE exposure_facts SET severity_rank=1 WHERE device_ord=1 AND pkg_ord=1")

    try do
      [first, second] = Prototype.compare!(run, [1, 2])
      refute first.matches
      assert first.source["count"] == first.warehouse["count"]
      assert second.matches
    after
      warehouse!("UPDATE exposure_facts SET severity_rank=4 WHERE device_ord=1 AND pkg_ord=1")
    end

    warehouse!("DELETE FROM exposure_facts WHERE device_ord=1 AND pkg_ord=1")

    try do
      [first] = Prototype.compare!(run, [1])
      refute first.matches
      assert first.source["count"] == first.warehouse["count"] + 1
    after
      insert_fact!(1)
    end
  end

  defp insert_fact!(ordinal) do
    warehouse!("""
    INSERT INTO exposure_facts (device_ord,cve_ord,pkg_ord,pkgver_ord,state,source_scope,
      severity_rank,cvss_score,kev,exploit_available,fix_available,first_exposed_at,
      resolved_at,updated_at,transition_seq,transition_xid,snapshot_generation,device_lifecycle_seq,payload_compacted)
    VALUES (#{ordinal},20260000001,1,1,1,'host',4,7.5,true,true,false,'2000-01-01',NULL,'2000-01-02',100000,11,1,0,false)
    """)
  end

  defp readiness_parity! do
    batch = Readiness.status_many!([1, 2])

    for ordinal <- [1, 2] do
      assert {:ok, expected} = ExposureReadiness.status(ordinal)
      assert Map.take(expected, [:ready, :reasons]) == batch[ordinal]
    end

    batch
  end

  defp shared_source_controls!(run) do
    [[first_publication], [second_publication]] =
      State.query!("""
      SELECT last_exposure_publication FROM platform.endpoint_vulnerability_assessments
      WHERE device_uid='sr:capacity-1' ORDER BY id LIMIT 2
      """)

    second_id = "00000000-0000-0000-0000-000000000002"

    # Two distinct source records can corruptly point at the same warehouse
    # fact. Reference deduplication must not discard either fact contribution.
    source_change!(
      second_id,
      "package_identity_key=$2,last_transition_seq=$3,last_exposure_publication=$4",
      [
        first_publication["package_identity_key"],
        first_publication["transition_seq"],
        first_publication
      ]
    )

    try do
      [first, second] = Prototype.compare!(run, [1, 2])
      assert first.source["count"] == 2500
      refute first.source == first.warehouse
      refute first.matches
      assert second.matches
      assert first.source_work.reference_occurrences > first.source_work.reference_memberships
      assert first.source_work.reference_memberships > first.source_work.dimension_keys
    after
      source_change!(
        second_id,
        "package_identity_key=$2,last_transition_seq=$3,last_exposure_publication=$4",
        [
          second_publication["package_identity_key"],
          second_publication["transition_seq"],
          second_publication
        ]
      )
    end

    source_change!(second_id, "last_exposure_publication=$2", [
      Map.put(second_publication, "cve_ord", "invalid")
    ])

    try do
      [first, second] = Prototype.compare!(run, [1, 2])
      assert first.replay_drift == 1
      assert first.missing_proofs > 0
      refute first.matches
      assert second.matches
    after
      source_change!(second_id, "last_exposure_publication=$2", [second_publication])
    end
  end

  defp watermark_reference!(run) do
    # This CVE is absent from these devices' assessments. Only the terminal
    # marker requires its proof, so an active-only coverage query cannot pass.
    State.query!("""
    INSERT INTO platform.exposure_fact_watermarks
      (device_uid,package_identity_key,cve_id,state,transition_seq,transition_xid,payload)
    SELECT 'sr:capacity-1','capacity-package-1','CVE-2026-50000','resolved',900000,'11'::xid8,
      last_exposure_publication || jsonb_build_object('cve_id','CVE-2026-50000',
        'cve_ord',20260050000,'state','resolved','transition_seq',900000,
        'resolved_at','2000-01-02T00:00:00')
    FROM platform.endpoint_vulnerability_assessments
    WHERE id='00000000-0000-0000-0000-000000000001'
    """)

    try do
      State.query!(
        "DELETE FROM platform.exposure_audit_proofs WHERE run_id=$1::text::uuid AND kind='cve' AND ordinal=20260050000",
        [run.id]
      )

      [first, second] = Prototype.compare!(run, [1, 2])
      assert first.source == first.warehouse
      refute first.matches
      assert first.missing_proofs == 1
      assert second.matches
      assert 1 == Prototype.dimensions!(run)
      assert [%{matches: true}] = Prototype.compare!(run, [1])

      State.query!("""
      UPDATE platform.exposure_fact_watermarks SET payload=jsonb_set(payload,'{cve_ord}','"invalid"')
      WHERE device_uid='sr:capacity-1' AND package_identity_key='capacity-package-1' AND cve_id='CVE-2026-50000'
      """)

      [first, second] = Prototype.compare!(run, [1, 2])
      refute first.matches
      assert first.missing_proofs == 1
      assert second.matches
    after
      State.query!("""
      DELETE FROM platform.exposure_fact_watermarks
      WHERE device_uid='sr:capacity-1' AND package_identity_key='capacity-package-1' AND cve_id='CVE-2026-50000'
      """)
    end
  end

  defp readiness_controls! do
    [[id]] =
      State.query!("""
      INSERT INTO platform.exposure_transition_outbox(device_uid,transition_seq,payload)
      SELECT device_uid,last_transition_seq,last_exposure_publication
      FROM platform.endpoint_vulnerability_assessments WHERE id='00000000-0000-0000-0000-000000000001'
      RETURNING id
      """)

    try do
      assert readiness_parity!()[1].ready

      State.query!(
        "UPDATE platform.exposure_transition_outbox SET inserted_at=now()-interval '11 minutes' WHERE id=$1",
        [
          id
        ]
      )

      assert :outbox_stale in readiness_parity!()[1].reasons
    after
      State.query!("DELETE FROM platform.exposure_transition_outbox WHERE id=$1", [id])
    end

    [[control]] =
      State.query!(
        "SELECT control FROM platform.exposure_reconciliation_checks WHERE device_ord=1"
      )

    try do
      State.query!(
        "UPDATE platform.exposure_reconciliation_checks SET control=jsonb_set(control,'{repairs}','[{" <>
          "\"synthetic\":true}]') WHERE device_ord=1"
      )

      assert :snapshot_recovery in readiness_parity!()[1].reasons
      assert readiness_parity!()[2].ready
    after
      State.query!(
        "UPDATE platform.exposure_reconciliation_checks SET control=$1 WHERE device_ord=1",
        [control]
      )
    end

    bucket =
      "sr:capacity-1"
      |> ServiceRadar.Inventory.ExposureTransitionRelay.subject()
      |> String.split(".")
      |> List.last()
      |> String.to_integer()

    State.query!(
      "INSERT INTO platform.exposure_delivery_batches(bucket,stream_sequences) VALUES($1,ARRAY[1]::bigint[])",
      [bucket]
    )

    try do
      assert :delivery_recovery in readiness_parity!()[1].reasons
    after
      State.query!("DELETE FROM platform.exposure_delivery_batches WHERE bucket=$1", [bucket])
    end
  end

  defp covering_snapshot!(run, result, previous_second) do
    [[generation]] =
      State.query!("""
      INSERT INTO platform.exposure_snapshot_generations(status,control,inserted_at,updated_at)
      VALUES('complete','{"scope":1}',clock_timestamp(),clock_timestamp()) RETURNING id
      """)

    try do
      assert [%{"status" => "deferred"}] = State.record!(run, [result])
      [first, second] = Prototype.compare!(run, [1, 2])
      refute first.matches
      assert first.missing_proofs > 0
      assert second.matches
      assert second.evidence_at == previous_second.evidence_at
      assert :comparison_pending in readiness_parity!()[1].reasons
    after
      State.query!("DELETE FROM platform.exposure_snapshot_generations WHERE id=$1", [generation])
      State.record!(run, [result])
    end
  end

  defp terminal_proof!(run) do
    State.query!(
      "DELETE FROM platform.exposure_audit_proofs WHERE run_id=$1::text::uuid AND kind='package' AND ordinal=2551",
      [run.id]
    )

    [result] = Prototype.compare!(run, [1])
    assert result.source == result.warehouse
    refute result.matches
    assert result.missing_proofs > 0
    assert 1 == Prototype.dimensions!(run)
  end

  defp dimension_failure!(run) do
    State.query!(
      "DELETE FROM platform.exposure_audit_proofs WHERE run_id=$1::text::uuid AND kind='cve' AND ordinal=20260000001",
      [run.id]
    )

    warehouse!("UPDATE exposure_cve_dim SET cve_id='CVE-2000-9999' WHERE cve_ord=20260000001")

    try do
      assert 1 == Prototype.dimensions!(run)
      [first, second] = Prototype.compare!(run, [1, 2])
      refute first.matches
      assert second.matches
    after
      warehouse!("UPDATE exposure_cve_dim SET cve_id='CVE-2026-0001' WHERE cve_ord=20260000001")
      assert 1 == Prototype.dimensions!(run)
    end
  end

  defp busy_device!(run) do
    {:ok, _} =
      ServiceRadar.Repo.transaction(fn ->
        State.query!("SELECT pg_advisory_xact_lock($1)", [320_102_347_440_129])

        [second, first] =
          Prototype.compare!(run, [2, 1], fn _ -> :ok end, fn comparisons ->
            # Result publication still owns the second device's session lock.
            assert [[false]] =
                     State.query!("SELECT pg_try_advisory_xact_lock($1)", [320_102_347_440_130])

            comparisons
          end)

        assert first.ordinal == 1
        assert second.ordinal == 2
        assert first.lock_busy
        refute first.matches
        assert second.matches

        # The dedicated session has exited; another backend can now acquire it.
        assert [[true]] =
                 State.query!("SELECT pg_try_advisory_xact_lock($1)", [320_102_347_440_130])
      end)
  end

  defp live_after_images!(run) do
    id = "00000000-0000-0000-0000-000000000001"

    [[publication]] =
      State.query!(
        "SELECT last_exposure_publication FROM platform.endpoint_vulnerability_assessments WHERE id=$1::text::uuid",
        [id]
      )

    source_change!(
      id,
      "last_transition_seq=40,last_exposure_publication=jsonb_set(last_exposure_publication,'{transition_seq}','40')"
    )

    warehouse!("UPDATE exposure_facts SET transition_seq=40 WHERE device_ord=1 AND pkg_ord=1")

    try do
      [during] =
        Prototype.compare!(run, [1], fn _ ->
          source_change!(
            id,
            "status='resolved',resolved_at='2000-01-02',last_transition_seq=41,last_exposure_publication=last_exposure_publication || jsonb_build_object('state','resolved','transition_seq',41,'resolved_at','2000-01-02T00:00:00')"
          )

          warehouse!(
            "UPDATE exposure_facts SET state=0,resolved_at='2000-01-02',transition_seq=41 WHERE device_ord=1 AND pkg_ord=1"
          )
        end)

      refute during.matches
      assert during.source["count"] == 2500 and during.warehouse["count"] == 2499
      assert [%{matches: true}] = Prototype.compare!(run, [1])

      source_change!(
        id,
        "status='active',resolved_at=NULL,last_transition_seq=42,last_exposure_publication=last_exposure_publication || jsonb_build_object('state','active','transition_seq',42,'resolved_at',NULL)"
      )

      warehouse!(
        "UPDATE exposure_facts SET state=1,resolved_at=NULL,transition_seq=42 WHERE device_ord=1 AND pkg_ord=1"
      )

      assert [%{matches: true}] = Prototype.compare!(run, [1])
    after
      source_change!(
        id,
        "status='active',resolved_at=NULL,last_transition_seq=100000,last_exposure_publication=$2",
        [
          publication
        ]
      )

      warehouse!(
        "UPDATE exposure_facts SET state=1,resolved_at=NULL,transition_seq=100000 WHERE device_ord=1 AND pkg_ord=1"
      )
    end
  end

  defp empty_device!(run) do
    mutate_devices!(fn ->
      State.query!("INSERT INTO platform.ocsf_devices(uid) VALUES('sr:capacity-empty')")

      State.query!(
        "INSERT INTO platform.device_fleet_ordinals(uid,ordinal) VALUES('sr:capacity-empty',201)"
      )
    end)

    try do
      assert [%{matches: true, source: %{"count" => 0}, warehouse: %{"count" => 0}}] =
               Prototype.compare!(run, [201])

      insert_fact!(201)

      assert [%{matches: false, source: %{"count" => 0}, warehouse: %{"count" => 1}}] =
               Prototype.compare!(run, [201])
    after
      warehouse!("DELETE FROM exposure_facts WHERE device_ord=201")

      mutate_devices!(fn ->
        State.query!("DELETE FROM platform.device_fleet_ordinals WHERE uid='sr:capacity-empty'")
        State.query!("DELETE FROM platform.ocsf_devices WHERE uid='sr:capacity-empty'")
      end)
    end
  end

  defp mutate_devices!(fun) do
    {:ok, _} =
      ServiceRadar.Repo.transaction(fn ->
        for table <- ~w(ocsf_devices device_fleet_ordinals),
            do: State.query!("ALTER TABLE platform.#{table} DISABLE TRIGGER USER")

        fun.()

        for table <- ~w(ocsf_devices device_fleet_ordinals),
            do: State.query!("ALTER TABLE platform.#{table} ENABLE TRIGGER USER")
      end)
  end

  defp source_change!(id, assignments, params \\ []) do
    {:ok, _} =
      ServiceRadar.Repo.transaction(fn ->
        State.query!(
          "ALTER TABLE platform.endpoint_vulnerability_assessments DISABLE TRIGGER USER"
        )

        State.query!(
          "UPDATE platform.endpoint_vulnerability_assessments SET #{assignments} WHERE id=$1::text::uuid",
          [
            id | params
          ]
        )

        State.query!(
          "ALTER TABLE platform.endpoint_vulnerability_assessments ENABLE TRIGGER USER"
        )
      end)
  end

  defp publication_validation! do
    [[base]] =
      State.query!(
        "SELECT last_exposure_publication FROM platform.endpoint_vulnerability_assessments ORDER BY id LIMIT 1"
      )

    cases = [
      base,
      Map.delete(base, "device_lifecycle_seq"),
      Map.put(base, "schema_version", 2),
      Map.put(base, "schema_version", 1.0),
      Map.put(base, "event_type", "device_retired"),
      Map.put(base, "device_ord", nil),
      Map.put(base, "transition_seq", "1"),
      Map.put(base, "transition_seq", 1.0),
      Map.put(base, "source_scope", String.duplicate("a", 33)),
      Map.put(base, "changed_at", "2000-02-30T01:02:03"),
      Map.put(base, "kev", 1),
      Map.put(base, "severity", %{}),
      Map.put(base, "cvss_score", 11),
      Map.delete(base, "resolved_at"),
      Map.put(base, "device_lifecycle_seq", base["transition_seq"])
    ]

    datetimes =
      ~w(2000-02-29T01:02:03 1900-02-29T01:02:03 0000-02-29T01:02:03 -0400-02-29T01:02:03 +2000-02-29T01:02:03 2000-02-29T24:00:00 2000-02-29T01:02:03Z 2000-02-29T01:02:03.1234567 2000-02-29T01:02:03,1234567 2000-02-29T01:02:03+02:30 2000-02-29T01:02:03-00:00 2000-02-29T01:02:03+24:00)

    cases = cases ++ Enum.map(datetimes, &Map.put(base, "changed_at", &1))

    for publication <- cases do
      expected =
        match?({:ok, [_]}, ExposureTransitions.decode([%{data: Jason.encode!(publication)}]))

      [[valid]] =
        State.query!("SELECT COALESCE(#{SQL.valid_publication("$1::jsonb")},false)", [publication])

      assert valid == expected, "SQL publication validation differs from decoder"
    end
  end
end
