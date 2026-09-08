defmodule ServiceRadar.Inventory.BumblebeeIngestorTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding
  alias ServiceRadar.Inventory.BumblebeeIngestor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceRiskContribution
  alias ServiceRadar.Repo
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

  test "does not clobber a backfilled device when the agent mapping is temporarily unresolved", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "bumblebee-stable-device-#{unique}")
    agent_id = "bumblebee-stable-agent-#{unique}"
    agent = create_agent!(actor, agent_id, device.uid)

    assert {:ok, first_result} =
             BumblebeeIngestor.ingest_scan(scan_payload(agent_id, unique), actor: actor)

    assert first_result.device_uid == device.uid

    agent
    |> Ash.Changeset.for_update(:reassign_device, %{device_uid: nil}, actor: actor)
    |> Ash.update!(actor: actor)

    assert {:ok, second_result} =
             BumblebeeIngestor.ingest_scan(
               scan_payload(agent_id, unique + 1, findings: []),
               actor: actor
             )

    assert second_result.device_uid == device.uid
    assert {:ok, posture} = BumblebeeDevicePosture.get_by_agent(agent_id, actor: actor)
    assert posture.device_uid == device.uid
    assert posture.run_id == "run-#{unique + 1}"

    assert {:ok, [contribution]} =
             DeviceRiskContribution.list_active_by_device(device.uid, actor: actor)

    assert contribution.source == "bumblebee"
    assert contribution.score == 40
  end

  test "resolves stale bumblebee risk contribution when an agent moves devices", %{actor: actor} do
    unique = System.unique_integer([:positive])
    original_device = create_device!(actor, "bumblebee-original-device-#{unique}")
    new_device = create_device!(actor, "bumblebee-new-device-#{unique}")
    agent_id = "bumblebee-moved-agent-#{unique}"
    agent = create_agent!(actor, agent_id, original_device.uid)

    assert {:ok, first_result} =
             BumblebeeIngestor.ingest_scan(scan_payload(agent_id, unique), actor: actor)

    assert first_result.device_uid == original_device.uid

    assert {:ok, [original_contribution]} =
             DeviceRiskContribution.list_active_by_device(original_device.uid, actor: actor)

    assert original_contribution.source == "bumblebee"

    agent
    |> Ash.Changeset.for_update(:reassign_device, %{device_uid: new_device.uid}, actor: actor)
    |> Ash.update!(actor: actor)

    assert {:ok, second_result} =
             BumblebeeIngestor.ingest_scan(scan_payload(agent_id, unique + 1), actor: actor)

    assert second_result.device_uid == new_device.uid

    assert {:ok, []} =
             DeviceRiskContribution.list_active_by_device(original_device.uid, actor: actor)

    assert {:ok, [new_contribution]} =
             DeviceRiskContribution.list_active_by_device(new_device.uid, actor: actor)

    assert new_contribution.source == "bumblebee"
    assert new_contribution.metadata["run_id"] == "run-#{unique + 1}"
  end

  test "backfills pending findings when an agent later resolves without re-reporting them", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    agent_id = "bumblebee-pending-finding-agent-#{unique}"

    assert {:ok, first_result} =
             BumblebeeIngestor.ingest_scan(scan_payload(agent_id, unique), actor: actor)

    assert first_result.device_uid == nil

    device = create_device!(actor, "bumblebee-pending-finding-device-#{unique}")
    create_agent!(actor, agent_id, device.uid)

    assert {:ok, second_result} =
             BumblebeeIngestor.ingest_scan(
               scan_payload(agent_id, unique + 1, findings: []),
               actor: actor
             )

    assert second_result.device_uid == device.uid

    finding = finding_by_agent!(agent_id, "finding-#{unique}")

    assert finding.device_uid == device.uid
    assert finding.status == "resolved"
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

  defp finding_by_agent!(agent_id, finding_id) do
    query =
      from(f in "bumblebee_findings",
        where: f.agent_id == ^agent_id and f.finding_id == ^finding_id,
        select: %{device_uid: f.device_uid, status: f.status},
        limit: 1
      )

    Repo.one!(query, prefix: "platform")
  end
end
