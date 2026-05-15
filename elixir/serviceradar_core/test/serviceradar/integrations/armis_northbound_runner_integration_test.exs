defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:armis_northbound_runner_integration_test)
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

  test "load_candidates can use a selected per-agent availability source", %{actor: actor} do
    source =
      create_source!(actor, "armis-per-agent",
        northbound_availability_source_agent_id: "agent-northbound"
      )

    ingest_armis_update(actor, source.id, "192.0.2.20", "armis-agent-1", false)
    ingest_armis_update(actor, source.id, "192.0.2.21", "armis-agent-2", true)

    {:ok, device_a} = Device.get_by_ip("192.0.2.20", false, actor: actor)
    {:ok, device_b} = Device.get_by_ip("192.0.2.21", false, actor: actor)

    create_agent_availability!(actor, device_a.uid, "agent-northbound", true)
    create_agent_availability!(actor, device_b.uid, "agent-other", false)

    assert {:ok, candidates} = ArmisNorthboundRunner.load_candidates(source)

    assert Enum.map(candidates, & &1.armis_device_id) == ["armis-agent-1"]
    assert Enum.map(candidates, & &1.is_available) == [true]
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
    |> Ash.Changeset.for_create(
      :create,
      attrs,
      actor: actor
    )
    |> Ash.Changeset.set_argument(:credentials, %{secret_key: "secret", api_key: "api"})
    |> Ash.create!(actor: actor)
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
end
