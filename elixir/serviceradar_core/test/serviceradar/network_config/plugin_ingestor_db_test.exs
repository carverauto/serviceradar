defmodule ServiceRadar.NetworkConfig.PluginIngestorDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkConfig.PluginIngestor
  alias ServiceRadar.NetworkConfig.Revision

  @moduletag :integration

  test "stores the operator-only revision and deletes its staged transport copy" do
    uid = "sr:host-#{System.unique_integer([:positive])}.example.com"
    key = "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/1001"
    body = "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n!\n"
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    actor = SystemActor.system(:network_config_ingest_test)

    payload = %{
      "labels" => %{
        "kind" => "running_config",
        "assignment_id" => "assign-01",
        "device_uid" => uid
      },
      "details" => %{"artifact" => %{"object_key" => key, "sha256" => hash}}
    }

    assert :ok =
             PluginIngestor.ingest(payload, %{agent_id: "agent-01"},
               actor: actor,
               artifact_fetcher: fn ^key -> {:ok, body} end,
               artifact_deleter: fn ^key ->
                 send(self(), :transport_deleted)
                 :ok
               end,
               projector: fn _uid, _revision, _facts -> :ok end
             )

    assert_received :transport_deleted
    assert {:ok, [revision]} = Revision.latest_for_device(uid, actor: actor)
    assert revision.body == body
    assert revision.content_hash == hash
  end
end
