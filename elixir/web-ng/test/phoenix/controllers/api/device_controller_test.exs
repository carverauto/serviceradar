defmodule ServiceRadarWebNGWeb.Api.DeviceControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadarWebNGWeb.Api.DeviceController

  setup :register_and_log_in_api_user

  test "show includes bumblebee exposure detail data", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    device = device_fixture(%{uid: "bumblebee-api-device-#{unique}"})
    now = DateTime.utc_now()

    BumblebeeDevicePosture
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device.uid,
        agent_id: "agent-#{unique}",
        run_id: "run-#{unique}",
        catalog_snapshot_ref: "snapshot-#{unique}",
        scanner_version: "serviceradar-bumblebee-test",
        state: "scanned",
        coverage_state: "partial",
        attempted_root_count: 3,
        scanned_root_count: 2,
        skipped_root_count: 1,
        root_covered: true,
        skipped_roots: [%{"path" => "/root", "reason" => "permission_denied"}],
        risk_score: 80,
        highest_severity: "high",
        active_finding_count: 1,
        last_successful_scan_at: now,
        last_scan_at: now,
        metadata: %{"catalog_version" => "catalog-v1"}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    BumblebeeFinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device.uid,
        agent_id: "agent-#{unique}",
        run_id: "run-#{unique}",
        finding_id: "finding-#{unique}",
        catalog_id: "catalog-entry-#{unique}",
        catalog_snapshot_ref: "snapshot-#{unique}",
        scanner_version: "serviceradar-bumblebee-test",
        severity: "high",
        risk_score: 80,
        ecosystem: "npm",
        package_name: "dev-server",
        package_version: "1.2.3",
        evidence: %{"path" => "/home/user/app/package.json"},
        confidence: "high",
        status: "active",
        first_seen_at: now,
        last_seen_at: now,
        metadata: %{}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    DeviceRiskReducer.upsert_contribution(%{
      device_uid: device.uid,
      source: "bumblebee",
      source_ref: "agent:agent-#{unique}",
      score: 80,
      reason: "Bumblebee detected 1 active developer endpoint exposure",
      occurred_at: now,
      metadata: %{"agent_id" => "agent-#{unique}"}
    })

    conn =
      conn
      |> assign(:current_scope, scope)
      |> DeviceController.show(%{"uid" => device.uid})

    bumblebee = json_response(conn, 200)["data"]["bumblebee"]

    assert bumblebee["summary"]["state"] == "scanned"
    assert bumblebee["summary"]["coverage_state"] == "partial"
    assert bumblebee["summary"]["catalog_snapshot_ref"] == "snapshot-#{unique}"
    assert bumblebee["summary"]["catalog_version"] == "catalog-v1"
    assert bumblebee["summary"]["active_finding_count"] == 1

    assert [%{"path" => "/root", "reason" => "permission_denied"}] =
             bumblebee["summary"]["skipped_roots"]

    assert [%{"agent_id" => agent_id, "active_finding_count" => 1}] = bumblebee["postures"]
    assert agent_id == "agent-#{unique}"

    assert [%{"finding_id" => finding_id, "package_name" => "dev-server"}] =
             bumblebee["active_findings"]

    assert finding_id == "finding-#{unique}"

    assert bumblebee["risk_contribution"]["source"] == "bumblebee"
    assert bumblebee["risk_contribution"]["score"] == 80
  end

  test "show reports finding count when posture has not arrived yet", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    device = device_fixture(%{uid: "bumblebee-api-no-posture-device-#{unique}"})
    now = DateTime.utc_now()

    BumblebeeFinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device.uid,
        agent_id: "agent-#{unique}",
        run_id: "run-#{unique}",
        finding_id: "finding-#{unique}",
        catalog_id: "catalog-entry-#{unique}",
        catalog_snapshot_ref: "snapshot-#{unique}",
        scanner_version: "serviceradar-bumblebee-test",
        severity: "medium",
        risk_score: 60,
        ecosystem: "python",
        package_name: "debug-console",
        package_version: "4.5.6",
        evidence: %{"path" => "/home/user/app/requirements.txt"},
        confidence: "medium",
        status: "active",
        first_seen_at: now,
        last_seen_at: now,
        metadata: %{}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    conn =
      conn
      |> assign(:current_scope, scope)
      |> DeviceController.show(%{"uid" => device.uid})

    summary = json_response(conn, 200)["data"]["bumblebee"]["summary"]

    assert summary["state"] == "not_scanned"
    assert summary["active_finding_count"] == 1
    assert summary["finding_count"] == 1
  end
end
