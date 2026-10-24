defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerIntegrationTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  import Ecto.Query, only: [where: 3]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.ArmisNorthboundLedger
  alias ServiceRadar.Integrations.ArmisNorthboundRetention
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.IntegrationUpdateRunTarget
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservationIngestor
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:armis_northbound_runner_integration_test)
    create_connected_agent!(actor)
    {:ok, actor: actor}
  end

  test "load_candidates returns only devices linked to the requested source", %{actor: actor} do
    source_a = create_source!(actor, "armis-source-a")
    source_b = create_source!(actor, "armis-source-b")

    ingest_armis_update(actor, source_a.id, TestSupport.unique_device_ip(), "armis-a-1", true)
    ingest_armis_update(actor, source_a.id, TestSupport.unique_device_ip(), "armis-a-2", false)
    ingest_armis_update(actor, source_b.id, TestSupport.unique_device_ip(), "armis-b-1", true)

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source_a)

    assert Enum.map(candidates, & &1.armis_device_id) == ["armis-a-1", "armis-a-2"]
    assert Enum.map(candidates, & &1.sync_service_id) == [source_a.id, source_a.id]
    assert Enum.map(candidates, & &1.is_available) == [true, false]
  end

  test "load_candidates includes Armis-discovered devices after sync registers typed identity", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-metadata-only")

    update = %{
      "ip" => TestSupport.unique_device_ip(),
      "mac" => unique_mac(),
      "hostname" => "armis-metadata-only-1",
      "source" => "armis",
      "is_available" => false,
      "metadata" => %{
        "armis_device_id" => "armis-metadata-only-1",
        "integration_type" => "armis"
      },
      "sync_meta" => %{
        "sync_service_id" => source.id
      }
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)

    assert Enum.map(candidates, & &1.armis_device_id) == ["armis-metadata-only-1"]
    assert Enum.map(candidates, & &1.sync_service_id) == [source.id]
    assert Enum.map(candidates, & &1.is_available) == [false]
  end

  test "legacy candidate queries accept only matching scoped metadata", %{actor: actor} do
    source = create_source!(actor, "scoped-source")
    ip = TestSupport.unique_device_ip()
    ingest_armis_update(actor, source.id, ip, "301", true)
    {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
    device = single_result(device)
    create_agent_availability!(actor, device.uid, "agent-scoped", true)

    for {integration_id, eligible?} <- [
          {"301", true},
          {"armis:#{source.id}:device:301", true},
          {"armis:other-source:device:301", false},
          {"armis:#{source.id}:device:302", false}
        ] do
      update_device_metadata!(actor, device, %{
        "armis_device_id" => "301",
        "integration_type" => "armis",
        "integration_id" => integration_id,
        "sync_service_id" => source.id
      })

      for candidate_source <- [
            source,
            %{source | northbound_availability_source_agent_id: "agent-scoped"}
          ] do
        candidates =
          Repo.all(ArmisNorthboundRunner.candidates_query(candidate_source))

        assert Enum.any?(candidates, &(&1.armis_device_id == "301")) == eligible?
      end

      assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)
      assert Enum.any?(candidates, &(&1.armis_device_id == "301")) == eligible?
    end
  end

  test "load_candidates skips typed Armis identifiers when device metadata disagrees", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-stale-metadata")

    ip = TestSupport.unique_device_ip()
    ingest_armis_update(actor, source.id, ip, "armis-current", true)

    {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
    device = single_result(device)

    update_device_metadata!(actor, device, %{
      "armis_device_id" => "armis-stale",
      "integration_id" => "armis-stale",
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)
    refute Enum.any?(candidates, &(&1.armis_device_id == "armis-current"))
  end

  test "load_candidates ignores generic Armis integration identifiers without typed identity", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-generic-only")
    armis_id = "armis-generic-only-#{System.unique_integer([:positive])}"

    device =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "generic-only-armis",
        ip: TestSupport.unique_device_ip(),
        is_available: false,
        discovery_sources: ["armis"],
        metadata: %{
          "integration_type" => "armis",
          "integration_id" => armis_id,
          "sync_service_id" => source.id
        }
      })

    register_identifier!(actor, device.uid, :integration_id, armis_id, %{
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)
    refute Enum.any?(candidates, &(&1.armis_device_id == armis_id))
  end

  test "load_candidates skips split typed and generic Armis identifier mappings", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-split-generic")
    armis_id = "armis-split-#{System.unique_integer([:positive])}"

    ingest_armis_update(actor, source.id, TestSupport.unique_device_ip(), armis_id, true)

    generic_device =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "split-generic-armis",
        ip: TestSupport.unique_device_ip(),
        is_available: false,
        discovery_sources: ["armis"],
        metadata: %{
          "integration_type" => "armis",
          "integration_id" => armis_id,
          "sync_service_id" => source.id
        }
      })

    register_identifier!(actor, generic_device.uid, :integration_id, armis_id, %{
      "integration_type" => "armis",
      "sync_service_id" => source.id
    })

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)
    refute Enum.any?(candidates, &(&1.armis_device_id == armis_id))
  end

  test "load_candidates can use a selected per-agent availability source", %{actor: actor} do
    source =
      create_source!(actor, "armis-per-agent",
        northbound_availability_source_agent_id: "agent-northbound"
      )

    ip_a = TestSupport.unique_device_ip()
    ip_b = TestSupport.unique_device_ip()
    ingest_armis_update(actor, source.id, ip_a, "armis-agent-1", false)
    ingest_armis_update(actor, source.id, ip_b, "armis-agent-2", true)

    {:ok, device_a} = Device.get_by_ip(ip_a, false, actor: actor)
    {:ok, device_b} = Device.get_by_ip(ip_b, false, actor: actor)
    device_a = single_result(device_a)
    device_b = single_result(device_b)

    create_agent_availability!(actor, device_a.uid, "agent-northbound", true)
    create_agent_availability!(actor, device_b.uid, "agent-other", false)

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)

    assert Enum.map(candidates, & &1.armis_device_id) == ["armis-agent-1"]
    assert Enum.map(candidates, & &1.is_available) == [true]
  end

  test "load_candidates fails when selected per-agent availability source has no rows", %{
    actor: actor
  } do
    source =
      create_source!(actor, "armis-per-agent-empty",
        northbound_availability_source_agent_id: "agent-empty"
      )

    ingest_armis_update(
      actor,
      source.id,
      TestSupport.unique_device_ip(),
      "armis-agent-empty-1",
      true
    )

    assert {:error, {:missing_agent_availability, "agent-empty"}} =
             ArmisNorthboundRunner.load_candidates(source)
  end

  # add-merged-device-availability, Decision 13: what a run pushes per source.
  describe "availability semantics" do
    test "an agent-selected source pushes the agent's result whether or not resolution ran",
         %{actor: actor} do
      source =
        create_source!(actor, "armis-control-agent",
          northbound_availability_source_agent_id: "agent-control"
        )

      ip = TestSupport.unique_device_ip()
      ingest_armis_update(actor, source.id, ip, "armis-control-1", true)
      device = ip |> Device.get_by_ip(false, actor: actor) |> elem(1) |> single_result()

      # The agent that should be blocked cannot reach the device; another agent can.
      create_agent_availability!(actor, device.uid, "agent-control", false)
      create_agent_availability!(actor, device.uid, "agent-witness", true)
      before = Repo.all(ArmisNorthboundRunner.candidates_query(source))

      # Resolution, as stage c runs it: the device row carries the merged state.
      set_availability_mode!("authoritative")
      set_canonical_state!(device.uid, "available", true)

      assert Repo.all(ArmisNorthboundRunner.candidates_query(source)) == before
      assert [%{armis_device_id: "armis-control-1", is_available: false}] = before
    end

    test "a legacy source pushes the compatibility value after cutover, not the merged state",
         %{actor: actor} do
      source = actor |> create_source!("armis-legacy") |> keep_legacy_semantics!()

      ip = TestSupport.unique_device_ip()
      ingest_armis_update(actor, source.id, ip, "armis-legacy-1", true)
      device = ip |> Device.get_by_ip(false, actor: actor) |> elem(1) |> single_result()

      # Seeded at cutover; no legacy writer touches it afterwards, while the resolver
      # decides the device unavailable.
      seed_legacy_value!(device.uid, true)
      set_availability_mode!("authoritative")
      set_canonical_state!(device.uid, "unavailable", false)

      assert {:ok, [%{armis_device_id: "armis-legacy-1", is_available: true}]} =
               ArmisNorthboundRunner.load_candidates(source)
    end

    test "a merged source pushes the canonical state and withholds unknown devices",
         %{actor: actor} do
      source = create_source!(actor, "armis-merged")
      assert source.northbound_availability_semantics == :merged

      [known_ip, unknown_ip] = for _ <- 1..2, do: TestSupport.unique_device_ip()
      ingest_armis_update(actor, source.id, known_ip, "armis-merged-1", true)
      ingest_armis_update(actor, source.id, unknown_ip, "armis-merged-2", true)

      [known, unknown] =
        for ip <- [known_ip, unknown_ip] do
          ip |> Device.get_by_ip(false, actor: actor) |> elem(1) |> single_result()
        end

      set_availability_mode!("authoritative")
      set_canonical_state!(known.uid, "unavailable", false)
      # Unknown keeps its last decided boolean, which merged semantics must not push.
      set_canonical_state!(unknown.uid, "unknown", true)

      assert {:ok, [%{armis_device_id: "armis-merged-1", is_available: false}]} =
               ArmisNorthboundRunner.load_candidates(source)
    end

    test "a new source cannot choose legacy without an agent; adopting merged is explicit",
         %{actor: actor} do
      assert_raise Ash.Error.Invalid,
                   ~r/legacy availability is kept only for existing sources/,
                   fn ->
                     create_source!(actor, "armis-new-legacy",
                       northbound_availability_semantics: :legacy
                     )
                   end

      source = actor |> create_source!("armis-adopt") |> keep_legacy_semantics!()

      assert {:ok, %{northbound_availability_semantics: :merged}} =
               source
               |> Ash.Changeset.for_update(:adopt_merged_availability, %{})
               |> Ash.update(actor: actor)
    end
  end

  test "run_for_source does not start another run while one is already running", %{actor: actor} do
    source = create_source!(actor, "armis-single-active-run")

    IntegrationUpdateRun
    |> Ash.Changeset.for_create(
      :start_run,
      %{
        integration_source_id: source.id,
        run_type: :armis_northbound,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    load_candidates = fn _source, _opts ->
      flunk("candidate loading should not run while a northbound run is active")
    end

    assert {:error, :northbound_run_already_active} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               load_candidates: load_candidates
             )
  end

  test "run binds one collection and persists terminal outcome for every source ID", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-accounted-run")

    devices =
      Enum.map(1..3, fn index ->
        armis_id = "armis-accounted-#{index}"
        ip = TestSupport.unique_device_ip()
        ingest_armis_update(actor, source.id, ip, armis_id, rem(index, 2) == 0)
        {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
        {armis_id, single_result(device)}
      end)

    activate_collection!(source, devices)

    execute_batches = fn _source, candidates, _opts ->
      ids = Enum.map(candidates, & &1.armis_device_id)

      {:error,
       %{
         device_count: 3,
         updated_count: 2,
         skipped_count: 0,
         error_count: 1,
         batch_count: 2,
         errors: [%{reason: :stopped_after_second_batch}],
         accepted_ids: Enum.take(ids, 2),
         failed_ids: [],
         unattempted_ids: Enum.drop(ids, 2)
       }}
    end

    assert {:error, %{run: run, result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               execute_batches: execute_batches
             )

    assert run.collection_id == "collection-accounted"
    assert run.distinct_source_ids == 3
    assert run.eligible_count == 3
    assert run.accepted_count == 2
    assert run.failed_count == 0
    assert run.unattempted_count == 1
    assert run.reconciliation_status == :degraded
    assert result.device_count == result.accepted_count + result.unattempted_count

    assert {:ok, targets} = IntegrationUpdateRunTarget.list_by_run(run.id, actor: actor)
    assert length(targets) == 3
    assert Enum.count(targets, &(&1.outcome == :accepted)) == 2
    assert Enum.count(targets, &(&1.outcome == :unattempted)) == 1
    refute Enum.any?(targets, &(&1.outcome == :pending))

    assert {:ok, 2} =
             ArmisNorthboundRetention.prune(
               now: ~U[2100-01-01 00:00:00.000000Z],
               retention_days: 30,
               batch_size: 100
             )

    assert {:ok, retained_targets} =
             IntegrationUpdateRunTarget.list_by_run(run.id, actor: actor)

    assert Enum.map(retained_targets, & &1.outcome) == [:unattempted]
  end

  test "records partial batch failure and retains failed and withheld conflict rows across retention prune",
       %{actor: actor} do
    source = create_source!(actor, "armis-partial-and-conflict-retention")

    devices =
      Enum.map(1..3, fn index ->
        armis_id = "armis-partial-#{index}"
        ip = TestSupport.unique_device_ip()
        ingest_armis_update(actor, source.id, ip, armis_id, true)
        {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
        {armis_id, single_result(device)}
      end)

    {_conflict_id, conflict_device} = Enum.at(devices, 2)

    register_identifier!(
      actor,
      conflict_device.uid,
      :armis_device_id,
      "armis-partial-conflict-extra",
      %{"sync_service_id" => source.id}
    )

    activate_collection!(source, devices)

    execute_batches = fn _source, candidates, _opts ->
      ids = Enum.map(candidates, & &1.armis_device_id)
      assert ids == ["armis-partial-1", "armis-partial-2"]

      {:error,
       %{
         device_count: 2,
         updated_count: 1,
         skipped_count: 0,
         error_count: 1,
         batch_count: 2,
         errors: [%{batch_index: 1, reason: {:http_status, 502, %{"message" => "bad gateway"}}}],
         accepted_ids: ["armis-partial-1"],
         failed_ids: ["armis-partial-2"],
         unattempted_ids: []
       }}
    end

    assert {:error, %{run: run, result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               execute_batches: execute_batches
             )

    assert run.collection_id == "collection-accounted"
    assert run.distinct_source_ids == 3
    assert run.eligible_count == 2
    assert run.withheld_count == 1
    assert run.accepted_count == 1
    assert run.failed_count == 1
    assert run.unattempted_count == 0
    assert run.reconciliation_status == :degraded
    assert result.withheld_reason_counts == %{"multiple_typed_ids_per_device" => 1}

    assert {:ok, 1} =
             ArmisNorthboundRetention.prune(
               now: ~U[2100-01-01 00:00:00.000000Z],
               retention_days: 30,
               batch_size: 100
             )

    assert {:ok, retained_targets} =
             IntegrationUpdateRunTarget.list_by_run(run.id, actor: actor)

    assert Enum.map(retained_targets, &{&1.source_object_id, &1.outcome, &1.reason}) == [
             {"armis-partial-2", :failed, nil},
             {"armis-partial-3", :withheld, "multiple_typed_ids_per_device"}
           ]

    assert {:ok, examples} = ArmisNorthboundLedger.examples(run.id)

    assert Enum.map(examples, &{&1.source_object_id, &1.outcome, &1.reason}) == [
             {"armis-partial-2", "failed", nil},
             {"armis-partial-3", "withheld", "multiple_typed_ids_per_device"}
           ]
  end

  test "idempotent rerun against the same activated collection preserves exact population and reconciliation counts",
       %{actor: actor} do
    source = create_source!(actor, "armis-idempotent-rerun")

    devices =
      Enum.map(1..3, fn index ->
        armis_id = "armis-rerun-#{index}"
        ip = TestSupport.unique_device_ip()
        ingest_armis_update(actor, source.id, ip, armis_id, true)
        {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
        {armis_id, single_result(device)}
      end)

    activate_collection!(source, devices)

    execute_batches = fn _source, candidates, _opts ->
      ids = Enum.map(candidates, & &1.armis_device_id)

      {:ok,
       %{
         device_count: length(ids),
         updated_count: length(ids),
         skipped_count: 0,
         error_count: 0,
         batch_count: 1,
         errors: [],
         accepted_ids: ids,
         failed_ids: [],
         unattempted_ids: []
       }}
    end

    assert {:ok, %{run: first_run, result: first_result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               execute_batches: execute_batches
             )

    assert {:ok, %{run: second_run, result: second_result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               execute_batches: execute_batches
             )

    for run <- [first_run, second_run] do
      assert run.collection_id == "collection-accounted"
      assert run.distinct_source_ids == 3
      assert run.eligible_count == 3
      assert run.withheld_count == 0
      assert run.accepted_count == 3
      assert run.failed_count == 0
      assert run.unattempted_count == 0
      assert run.reconciliation_status == :reconciled
    end

    assert first_result.accepted_count == second_result.accepted_count
    assert first_result.collection == second_result.collection

    assert {:ok, population} =
             ServiceRadar.Integrations.ArmisNorthboundPopulation.load(source)

    assert {:ok, refinalized} =
             ArmisNorthboundLedger.finalize(first_run, population, first_result)

    assert refinalized.accepted_count == 3
    assert refinalized.reconciliation_status == :reconciled
  end

  test "legacy collection without exact accounting stays accounting_unavailable", %{actor: actor} do
    source = create_source!(actor, "armis-legacy-collection")

    devices =
      Enum.map(1..3, fn index ->
        armis_id = "armis-legacy-#{index}"
        ip = TestSupport.unique_device_ip()
        ingest_armis_update(actor, source.id, ip, armis_id, true)
        {:ok, device} = Device.get_by_ip(ip, false, actor: actor)
        {armis_id, single_result(device)}
      end)

    activate_collection!(source, devices, %{"accounting_status" => "unavailable"})

    assert {:error, %{run: run, result: result}} =
             ArmisNorthboundRunner.run_for_source(source, actor: actor)

    assert run.status == :failed
    assert run.collection_id == nil
    assert run.reconciliation_status == :unavailable
    assert run.error_message =~ "accounting_unavailable"
    assert result.errors == [%{reason: :accounting_unavailable}]
  end

  # One target row per distinct Armis source ID, 11 bound parameters each: a
  # collection of a few thousand IDs crosses Postgres's 65535-parameter
  # statement limit, which failed the whole bind with "postgresql protocol can
  # not handle N parameters".
  test "binds a collection larger than one statement's parameter limit", %{actor: actor} do
    source = create_source!(actor, "armis-large-collection")
    count = div(65_535, 11) + 50

    withheld =
      for index <- 1..count do
        %{
          disposition: :withheld,
          reason: "unresolved_canonical_identity",
          source_object_id: "armis-large-#{index}",
          canonical_device_uid: nil,
          is_available: nil,
          metadata: %{}
        }
      end

    population = %{
      accounted?: true,
      snapshot: %{activated_at: DateTime.utc_now()},
      eligible: [],
      withheld: withheld,
      distinct_source_ids: count,
      eligible_count: 0,
      withheld_count: count,
      reason_counts: %{"unresolved_canonical_identity" => count},
      accounting: %{
        collection_id: "collection-large",
        collection_content_hash: String.duplicate("c", 64),
        collection_observed_at: ~U[2026-09-01 08:00:00.000000Z],
        raw_rows: count,
        excluded_rows: 0,
        invalid_rows: 0,
        valid_occurrences: count,
        distinct_source_ids: count,
        duplicate_occurrences: 0,
        conflicting_duplicate_ids: 0
      }
    }

    run =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(:start_run, %{
        integration_source_id: source.id,
        run_type: :armis_northbound,
        metadata: %{}
      })
      |> Ash.create!(actor: actor)

    assert {:ok, bound} = ArmisNorthboundLedger.bind(run, population, actor)
    assert bound.distinct_source_ids == count

    targets =
      IntegrationUpdateRunTarget
      |> where([target], target.integration_update_run_id == ^run.id)
      |> Repo.aggregate(:count)

    assert targets == count
  end

  defp create_source!(actor, name, attrs \\ []) do
    attrs =
      Map.merge(
        %{
          name: name,
          source_type: :armis,
          endpoint: "https://example.invalid/#{System.unique_integer([:positive])}",
          northbound_enabled: true,
          custom_fields: ["availability"]
        },
        Map.new(attrs)
      )

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{secret_key: "secret", api_key: "api"})
    |> Ash.Changeset.for_create(
      :create,
      attrs,
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.load!([:credentials_encrypted, :credentials], actor: actor)
  end

  # A source created before merged availability: `legacy` semantics, which new sources
  # cannot choose.
  defp keep_legacy_semantics!(source) do
    Repo.query!(
      "UPDATE platform.integration_sources SET northbound_availability_semantics = 'legacy' WHERE id = $1",
      [Ecto.UUID.dump!(source.id)]
    )

    %{source | northbound_availability_semantics: :legacy}
  end

  defp set_availability_mode!(mode) do
    Repo.query!("UPDATE platform.availability_settings SET mode = $1", [mode])
  end

  # The device row as the resolver leaves it from cutover on.
  defp set_canonical_state!(uid, state, available?) do
    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET availability_state = $2, is_available = $3,
          availability_decided_by = jsonb_build_object('rule', 'highest_class')
      WHERE uid = $1
      """,
      [uid, state, available?]
    )
  end

  defp seed_legacy_value!(uid, available?) do
    Repo.query!(
      """
      INSERT INTO platform.device_availability_legacy (device_uid, is_available)
      VALUES ($1, $2)
      ON CONFLICT (device_uid) DO UPDATE SET is_available = EXCLUDED.is_available
      """,
      [uid, available?]
    )
  end

  defp create_connected_agent!(actor) do
    uid = "armis-northbound-agent-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp activate_collection!(source, devices, metadata_overrides \\ %{}) do
    observed_at = ~U[2026-09-01 08:00:00.000000Z]
    content_hash = String.duplicate("a", 64)

    snapshot = %{
      partition: source.partition || "default",
      source: "armis",
      source_instance: to_string(source.id),
      collection_id: "collection-accounted",
      content_hash: content_hash,
      query_hash: nil,
      observed_at: observed_at,
      metadata:
        Map.merge(
          %{
            "accounting_status" => "exact",
            "raw_rows" => 4,
            "excluded_rows" => 0,
            "invalid_rows" => 0,
            "valid_occurrences" => 4,
            "distinct_source_ids" => 3,
            "duplicate_occurrences" => 1,
            "conflicting_duplicate_ids" => 0
          },
          metadata_overrides
        )
    }

    observations =
      Enum.map(devices, fn {armis_id, device} ->
        %{
          device_id: device.uid,
          partition: snapshot.partition,
          source: "armis",
          source_instance: snapshot.source_instance,
          source_object_id: armis_id,
          source_integration_id: "armis:source:#{source.id}:#{armis_id}",
          collection_id: snapshot.collection_id,
          content_hash: content_hash,
          query_hash: nil,
          present: true,
          first_observed_at: observed_at,
          last_observed_at: observed_at,
          absent_since: nil,
          hostname: device.hostname,
          ip: device.ip,
          mac: device.mac,
          serial_number: nil,
          vendor_name: nil,
          model: nil,
          device_type: nil,
          site_name: nil,
          management_status: nil,
          metadata: %{
            "identifier_metadata" => %{"sync_service_id" => to_string(source.id)}
          }
        }
      end)

    assert :ok = DeviceSourceObservationIngestor.activate_resolved(snapshot, observations)
  end

  defp create_device!(actor, attrs) do
    Device
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp register_identifier!(actor, device_uid, type, value, metadata) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        metadata: metadata
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp update_device_metadata!(actor, device, metadata) do
    device
    |> Ash.Changeset.for_update(:update, %{metadata: metadata}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp ingest_armis_update(actor, sync_service_id, ip, armis_device_id, is_available) do
    update = %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => "armis-#{armis_device_id}",
      "source" => "armis",
      "is_available" => is_available,
      "metadata" => %{
        "armis_device_id" => armis_device_id,
        "integration_id" => armis_device_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{
        "sync_service_id" => sync_service_id
      }
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)
  end

  defp create_agent_availability!(actor, device_uid, agent_id, is_available) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: is_available,
        checked_at: DateTime.utc_now()
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp unique_mac do
    suffix =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(16)
      |> String.pad_leading(10, "0")

    suffix
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&"02:#{&1}")
  end

  defp single_result([result]), do: result
  defp single_result(result), do: result

  describe "composite export wiring" do
    defp composite_check!(actor, name) do
      check =
        ServiceRadar.CompositeChecks.CompositeCheck
        |> Ash.Changeset.for_create(
          :create,
          %{name: name, scope_query: "in:devices"},
          actor: actor
        )
        |> Ash.create!()

      ServiceRadar.CompositeChecks.CompositeCheckInput
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          key: "witness",
          label: "witness",
          position: 0,
          kind: :vantage_point,
          expected: "available",
          config: %{"agent_id" => "witness"}
        },
        actor: actor
      )
      |> Ash.create!()

      check
      |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true}, actor: actor)
      |> Ash.update!()
    end

    defp nb_device!(actor, ip, uid) do
      create_device!(actor, %{uid: uid, hostname: "nb-#{uid}", ip: ip})
    end

    defp composite_result!(actor, device_uid, check, verdict, status) do
      now = DateTime.utc_now()

      ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: device_uid,
          check_id: check.id,
          verdict: verdict,
          status: status,
          inputs: %{},
          evaluated_at: now,
          changed_at: now
        },
        actor: actor,
        upsert?: true,
        upsert_identity: :unique_device_check
      )
      |> Ash.create!()
    end

    defp capture_payloads(source, candidates, actor) do
      parent = self()

      request = fn _path, _method, _headers, body, _opts ->
        send(parent, {:payload, body})
        {:ok, %{status: 200, body: %{"success" => true}}}
      end

      assert {:ok, _result} =
               ArmisNorthboundRunner.execute_batches(source, candidates,
                 token_fetcher: fn _source -> {:ok, "token"} end,
                 request: request,
                 actor: actor
               )

      receive do
        {:payload, body} -> body
      after
        1_000 -> flunk("no bulk payload was sent")
      end
    end

    test "a run with a configured export sends the verdict alongside availability", %{
      actor: actor
    } do
      device = nb_device!(actor, TestSupport.unique_device_ip(), "armis-composite-1")
      check = composite_check!(actor, "NB Verdict #{System.unique_integer([:positive])}")
      composite_result!(actor, device.uid, check, "not_isolated", :down)

      source =
        create_source!(actor, "armis-composite-verdict",
          settings: %{
            "composite" => %{
              "check_slug" => check.slug,
              "value_form" => "verdict",
              "custom_field" => "sr_isolation"
            }
          }
        )

      candidates = [
        %{
          armis_device_id: "armis-composite-1",
          is_available: true,
          device_ids: [device.uid],
          sync_service_ids: [source.id],
          metadata: %{}
        }
      ]

      payload = capture_payloads(source, candidates, actor)

      assert Enum.any?(payload, fn entry ->
               match?(%{"customProperties" => %{"sr_isolation" => "not_isolated"}}, entry)
             end),
             "expected the composite value in #{inspect(payload)}"
    end

    test "a run with the status form sends the status enum", %{actor: actor} do
      device = nb_device!(actor, TestSupport.unique_device_ip(), "armis-composite-2")
      check = composite_check!(actor, "NB Status #{System.unique_integer([:positive])}")
      composite_result!(actor, device.uid, check, "not_isolated", :down)

      source =
        create_source!(actor, "armis-composite-status",
          settings: %{
            "composite" => %{
              "check_slug" => check.slug,
              "value_form" => "status",
              "custom_field" => "sr_isolation"
            }
          }
        )

      candidates = [
        %{
          armis_device_id: "armis-composite-2",
          is_available: true,
          device_ids: [device.uid],
          sync_service_ids: [source.id],
          metadata: %{}
        }
      ]

      payload = capture_payloads(source, candidates, actor)

      assert Enum.any?(payload, fn entry ->
               match?(%{"customProperties" => %{"sr_isolation" => "down"}}, entry)
             end),
             "expected the status value in #{inspect(payload)}"
    end

    test "a device with no result sends no composite key at all", %{actor: actor} do
      device = nb_device!(actor, TestSupport.unique_device_ip(), "armis-composite-3")
      check = composite_check!(actor, "NB Absent #{System.unique_integer([:positive])}")

      source =
        create_source!(actor, "armis-composite-absent",
          settings: %{
            "composite" => %{
              "check_slug" => check.slug,
              "value_form" => "verdict",
              "custom_field" => "sr_isolation"
            }
          }
        )

      candidates = [
        %{
          armis_device_id: "armis-composite-3",
          is_available: true,
          device_ids: [device.uid],
          sync_service_ids: [source.id],
          metadata: %{}
        }
      ]

      payload = capture_payloads(source, candidates, actor)

      # No placeholder, no empty string, no entry.
      refute Enum.any?(payload, fn entry ->
               entry |> Map.get("customProperties", %{}) |> Map.has_key?("sr_isolation")
             end)

      assert Enum.any?(payload, fn entry ->
               entry |> Map.get("customProperties", %{}) |> Map.has_key?("availability")
             end)
    end

    test "a source with no export configured sends availability only", %{actor: actor} do
      device = nb_device!(actor, TestSupport.unique_device_ip(), "armis-composite-4")
      source = create_source!(actor, "armis-composite-none")

      candidates = [
        %{
          armis_device_id: "armis-composite-4",
          is_available: true,
          device_ids: [device.uid],
          sync_service_ids: [source.id],
          metadata: %{}
        }
      ]

      payload = capture_payloads(source, candidates, actor)

      assert [%{"customProperties" => properties}] = payload
      assert Map.keys(properties) == ["availability"]
    end
  end
end
