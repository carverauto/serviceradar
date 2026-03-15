defmodule ServiceRadar.Inventory.SyncIngestorAgentIdTest do
  @moduledoc """
  Tests that sync ingestion registers agent_id as a strong identifier
  in device_identifiers so DIRE can deduplicate agent-reported devices.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_agent_id_test)
    {:ok, actor: actor}
  end

  describe "agent_id identifier registration" do
    test "sync ingestion with agent_id registers it in device_identifiers", %{actor: actor} do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      ip = "10.50.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      update = %{
        "ip" => ip,
        "hostname" => "k8s-pod-test",
        "source" => "agent",
        "metadata" => %{"agent_id" => agent_id}
      }

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      # Verify agent_id was registered as a strong identifier
      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.confidence == :strong
    end
  end
end
