defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
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

  defp create_source!(actor, name) do
    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        source_type: :armis,
        endpoint: "https://example.invalid/#{System.unique_integer([:positive])}",
        northbound_enabled: true,
        custom_fields: ["availability"]
      },
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
