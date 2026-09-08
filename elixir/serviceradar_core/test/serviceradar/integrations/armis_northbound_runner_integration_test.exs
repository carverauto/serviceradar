defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerIntegrationTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
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

    ingest_armis_update(actor, source_a.id, "192.0.2.10", "armis-a-1", true)
    ingest_armis_update(actor, source_a.id, "192.0.2.11", "armis-a-2", false)
    ingest_armis_update(actor, source_b.id, "192.0.2.12", "armis-b-1", true)

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
      "ip" => "192.0.2.13",
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

  test "load_candidates skips typed Armis identifiers when device metadata disagrees", %{
    actor: actor
  } do
    source = create_source!(actor, "armis-stale-metadata")

    ingest_armis_update(actor, source.id, "192.0.2.14", "armis-current", true)

    {:ok, device} = Device.get_by_ip("192.0.2.14", false, actor: actor)
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
        ip: "192.0.2.15",
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

    ingest_armis_update(actor, source.id, "192.0.2.16", armis_id, true)

    generic_device =
      create_device!(actor, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "split-generic-armis",
        ip: "192.0.2.17",
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

    ingest_armis_update(actor, source.id, "192.0.2.20", "armis-agent-1", false)
    ingest_armis_update(actor, source.id, "192.0.2.21", "armis-agent-2", true)

    {:ok, device_a} = Device.get_by_ip("192.0.2.20", false, actor: actor)
    {:ok, device_b} = Device.get_by_ip("192.0.2.21", false, actor: actor)
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

    ingest_armis_update(actor, source.id, "192.0.2.22", "armis-agent-empty-1", true)

    assert {:error, {:missing_agent_availability, "agent-empty"}} =
             ArmisNorthboundRunner.load_candidates(source)
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
        ip = "192.0.2.#{30 + index}"
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

  defp create_connected_agent!(actor) do
    uid = "armis-northbound-agent-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp activate_collection!(source, devices) do
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
      metadata: %{
        "accounting_status" => "exact",
        "raw_rows" => 4,
        "excluded_rows" => 0,
        "invalid_rows" => 0,
        "valid_occurrences" => 4,
        "distinct_source_ids" => 3,
        "duplicate_occurrences" => 1,
        "conflicting_duplicate_ids" => 0
      }
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
      device = nb_device!(actor, "192.0.2.90", "armis-composite-1")
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
      device = nb_device!(actor, "192.0.2.91", "armis-composite-2")
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
      device = nb_device!(actor, "192.0.2.92", "armis-composite-3")
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
      device = nb_device!(actor, "192.0.2.93", "armis-composite-4")
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
