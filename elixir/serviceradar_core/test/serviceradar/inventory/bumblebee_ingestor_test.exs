defmodule ServiceRadar.Inventory.BumblebeeIngestorTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding
  alias ServiceRadar.Inventory.BumblebeeIngestor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceRiskContribution
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:bumblebee_ingestor_test)}
  end

  test "associates posture and findings to the reporting agent device", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "bumblebee-device-#{unique}")
    agent_id = "bumblebee-agent-#{unique}"
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, result} =
             BumblebeeIngestor.ingest_scan(scan_payload(agent_id, unique),
               actor: actor
             )

    assert result.device_uid == device.uid
    assert result.active_finding_count == 1

    assert {:ok, posture} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert posture.device_uid == device.uid
    assert posture.catalog_snapshot_ref == "snapshot-#{unique}"
    assert posture.coverage_state == "partial"
    assert posture.active_finding_count == 1

    assert {:ok, [finding]} =
             BumblebeeFinding.list_active_by_device(device.uid, actor: actor)

    assert finding.device_uid == device.uid
    assert finding.agent_id == agent_id
    assert finding.finding_id == "finding-#{unique}"

    assert {:ok, [contribution]} =
             DeviceRiskContribution.list_active_by_device(device.uid, actor: actor)

    assert contribution.source == "bumblebee"
    assert contribution.score == 80
  end

  test "backfills pending agent-only posture when the agent later resolves to a device", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    agent_id = "bumblebee-pending-agent-#{unique}"

    assert {:ok, first_result} =
             BumblebeeIngestor.ingest_scan(
               scan_payload(agent_id, unique, findings: []),
               actor: actor
             )

    assert first_result.device_uid == nil
    assert {:ok, pending} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert pending.device_uid == nil

    device = create_device!(actor, "bumblebee-backfill-device-#{unique}")
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, second_result} =
             BumblebeeIngestor.ingest_scan(
               scan_payload(agent_id, unique + 1, findings: []),
               actor: actor
             )

    assert second_result.device_uid == device.uid
    assert {:ok, backfilled} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert backfilled.device_uid == device.uid
    assert backfilled.run_id == "run-#{unique + 1}"
  end

  defp scan_payload(agent_id, unique, opts \\ []) do
    findings =
      Keyword.get(opts, :findings, [
        %{
          "finding_id" => "finding-#{unique}",
          "catalog_id" => "catalog-#{unique}",
          "severity" => "high",
          "risk_score" => 80,
          "ecosystem" => "npm",
          "package_name" => "dev-server",
          "package_version" => "1.2.3",
          "evidence" => %{"path" => "/home/app/package.json"},
          "confidence" => "high"
        }
      ])

    %{
      "agent_id" => agent_id,
      "run_id" => "run-#{unique}",
      "catalog_snapshot_ref" => "snapshot-#{unique}",
      "scanner_version" => "serviceradar-bumblebee-test",
      "state" => "scanned",
      "coverage_state" => "partial",
      "attempted_root_count" => 2,
      "scanned_root_count" => 1,
      "skipped_root_count" => 1,
      "root_covered" => false,
      "skipped_roots" => [%{"path" => "/root", "reason" => "permission_denied"}],
      "last_scan_at" => DateTime.utc_now(),
      "findings" => findings,
      "metadata" => %{"catalog_version" => "catalog-v#{unique}"}
    }
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{uid}.local",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_agent!(actor, agent_id, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_id,
        name: agent_id,
        type_id: 0,
        device_uid: device_uid,
        capabilities: ["bumblebee"]
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
