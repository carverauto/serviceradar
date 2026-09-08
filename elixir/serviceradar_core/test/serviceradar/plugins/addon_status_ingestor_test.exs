defmodule ServiceRadar.Plugins.AddonStatusIngestorTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Plugins.AddonStatusIngestor

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, agent_uid: "addon-status-agent-#{:erlang.unique_integer([:positive])}"}
  end

  defp agent_status(agent_uid, sidecars) do
    payload = Jason.encode!(%{"capabilities" => [], "sidecars" => sidecars})

    %{
      service_name: "agent",
      service_type: "agent",
      source: "status",
      agent_id: agent_uid,
      message: payload
    }
  end

  defp statuses_for(agent_uid) do
    AddonStatus
    |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid}, actor: SystemActor.system(:test))
    |> Ash.read!()
  end

  test "ingests addon sidecars into the read model, ignoring non-addon sidecars", %{
    agent_uid: agent_uid
  } do
    :ok =
      AddonStatusIngestor.ingest(
        agent_status(agent_uid, [
          %{
            "name" => "addon:sample",
            "state" => "running",
            "pid" => 1234,
            "restart_count" => 0,
            "version" => "0.2.0",
            "arch" => "arm64"
          },
          %{
            "name" => "addon:broken",
            "state" => "circuit_open",
            "restart_count" => 5,
            "last_error" => "boom"
          },
          %{"name" => "netprobe", "state" => "running"}
        ])
      )

    by_id = Map.new(statuses_for(agent_uid), &{&1.addon_id, &1})

    assert map_size(by_id) == 2
    refute Map.has_key?(by_id, "netprobe")

    assert by_id["sample"].state == "running"
    assert by_id["sample"].active == true
    assert by_id["sample"].pid == 1234
    assert by_id["sample"].version == "0.2.0"
    assert by_id["sample"].arch == "arm64"

    assert by_id["broken"].state == "circuit_open"
    assert by_id["broken"].active == false
    assert by_id["broken"].degradation_reason == "boom"
    assert by_id["broken"].restart_count == 5
  end

  test "re-ingest upserts the existing row instead of duplicating", %{agent_uid: agent_uid} do
    :ok =
      AddonStatusIngestor.ingest(
        agent_status(agent_uid, [%{"name" => "addon:sample", "state" => "running"}])
      )

    assert [initial] = statuses_for(agent_uid)
    initial_reported_at = initial.reported_at
    initial_updated_at = initial.updated_at

    Process.sleep(5)

    :ok =
      AddonStatusIngestor.ingest(
        agent_status(agent_uid, [
          %{"name" => "addon:sample", "state" => "unhealthy", "last_error" => "degraded"}
        ])
      )

    assert [row] = statuses_for(agent_uid)
    assert row.state == "unhealthy"
    assert row.active == false
    assert row.degradation_reason == "degraded"
    assert DateTime.after?(row.reported_at, initial_reported_at)
    assert DateTime.after?(row.updated_at, initial_updated_at)
  end
end
