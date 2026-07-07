defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
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
      }
    }

    :ok = SyncIngestor.ingest_updates([update], actor: actor)

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)

    assert Enum.map(candidates, & &1.armis_device_id) == ["armis-metadata-only-1"]
    assert Enum.map(candidates, & &1.sync_service_id) == [nil]
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

    assert {:ok, []} = ArmisNorthboundRunner.load_candidates(source)
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

    assert {:ok, []} = ArmisNorthboundRunner.load_candidates(source)
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

    assert {:ok, []} = ArmisNorthboundRunner.load_candidates(source)
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
  end

  defp create_connected_agent!(actor) do
    uid = "armis-northbound-agent-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(:register_connected, %{uid: uid, name: uid}, actor: actor)
    |> Ash.create!(actor: actor)
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
end
