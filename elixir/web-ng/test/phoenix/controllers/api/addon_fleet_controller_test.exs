defmodule ServiceRadarWebNGWeb.Api.AddonFleetControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.AddonFleetController

  defmodule FleetReaderStub do
    @moduledoc false

    def overview(opts) do
      send(self(), {:addon_fleet_options, opts})
      Process.get(:addon_fleet_overview, %{rows: [], catalog_only: []})
    end
  end

  setup %{conn: conn} do
    previous = Application.get_env(:serviceradar_web_ng, :addon_fleet_reader)
    Application.put_env(:serviceradar_web_ng, :addon_fleet_reader, FleetReaderStub)

    on_exit(fn ->
      Process.delete(:addon_fleet_overview)

      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :addon_fleet_reader)
      else
        Application.put_env(:serviceradar_web_ng, :addon_fleet_reader, previous)
      end
    end)

    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer})
    %{conn: log_in_api_user(conn, user), user: user}
  end

  test "requires authentication", %{conn: conn} do
    response =
      conn
      |> delete_req_header("authorization")
      |> get(~p"/api/addon-fleet")
      |> json_response(401)

    assert response["error"] == "authentication_required"
    refute_received {:addon_fleet_options, _opts}
  end

  test "requires edge-management permission before reading", %{conn: conn, user: user} do
    response =
      conn
      |> assign(:current_scope, Scope.for_user(user, permissions: MapSet.new()))
      |> AddonFleetController.index(%{})
      |> json_response(403)

    assert response["error"] == "forbidden"
    refute_received {:addon_fleet_options, _opts}
  end

  test "returns fleet category, reason, and freshness fields", %{conn: conn, user: user} do
    Process.put(:addon_fleet_overview, %{rows: [fleet_row()], catalog_only: []})
    scope = Scope.for_user(user, permissions: MapSet.new(["settings.edge.manage"]))

    response =
      conn
      |> assign(:current_scope, scope)
      |> AddonFleetController.index(%{"category" => "action_required", "limit" => "25"})
      |> json_response(200)

    assert_received {:addon_fleet_options, [scope: ^scope]}
    assert response["schema_version"] == "serviceradar.addon_fleet.v1"
    assert response["summary"]["action_required"] == 1
    assert response["pagination"] == %{"has_more" => false, "limit" => 25, "total" => 1}

    assert response["rows"] == [
             %{
               "active" => false,
               "addon_id" => "netprobe",
               "addon_name" => "Netprobe",
               "agent_label" => "edge-a (agent-a)",
               "agent_uid" => "agent-a",
               "assigned" => true,
               "assigned_version" => "1.2.3",
               "category" => "action_required",
               "degradation_reason" => nil,
               "evidence_age_seconds" => 42,
               "observed_at" => "2026-07-20T12:00:00Z",
               "observed_state" => "failed",
               "observed_version" => "1.2.3",
               "package_status" => "approved",
               "reason_code" => "unsupported_platform",
               "rollout_state" => "failed",
               "update_policy" => "manual_pin"
             }
           ]
  end

  test "rejects unknown or unbounded query parameters", %{conn: conn, user: user} do
    scope = Scope.for_user(user, permissions: MapSet.new(["settings.edge.manage"]))

    for params <- [%{"unknown" => "value"}, %{"limit" => "501"}, %{"limit" => "none"}] do
      response =
        conn
        |> assign(:current_scope, scope)
        |> AddonFleetController.index(params)
        |> json_response(400)

      assert response == %{"error" => "invalid_query", "message" => "Invalid add-on fleet query"}
    end

    refute_received {:addon_fleet_options, _opts}
  end

  defp fleet_row do
    %{
      agent_uid: "agent-a",
      agent_label: "edge-a (agent-a)",
      addon_id: "netprobe",
      addon_name: "Netprobe",
      assigned?: true,
      enabled?: true,
      assigned_version: "1.2.3",
      running_state: "failed",
      running_version: "1.2.3",
      active?: false,
      category: :action_required,
      reason_code: "unsupported_platform",
      evidence_age_seconds: 42,
      reported_at: ~U[2026-07-20 12:00:00Z],
      rollout_state: :failed,
      update_policy: :manual_pin,
      package_status: :approved,
      degradation_reason: nil,
      attention?: true
    }
  end
end
