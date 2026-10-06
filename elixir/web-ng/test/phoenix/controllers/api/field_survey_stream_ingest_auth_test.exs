defmodule ServiceRadarWebNGWeb.Api.FieldSurveyStreamIngestAuthTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 3]
  import Plug.Conn

  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.FieldSurveyStreamController

  @moduletag :db_free

  test "a viewer cannot open an ingest stream" do
    for {action, path} <- [
          {:rf_observations, "/v1/field-survey/survey-1/rf-observations"},
          {:pose_samples, "/v1/field-survey/survey-1/pose-samples"},
          {:spectrum_observations, "/v1/field-survey/survey-1/spectrum-observations"}
        ] do
      conn =
        apply(FieldSurveyStreamController, action, [
          conn(path, :viewer),
          %{"session_id" => "survey-1"}
        ])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "missing_permission"
    end
  end

  test "a viewer cannot upload a room artifact" do
    conn =
      FieldSurveyStreamController.room_artifacts(
        conn("/v1/field-survey/survey-1/room-artifacts", :viewer),
        %{
          "session_id" => "survey-1"
        }
      )

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "missing_permission"
  end

  test "an operator reaches the websocket check and does not write a session" do
    conn =
      FieldSurveyStreamController.rf_observations(
        conn("/v1/field-survey/survey-1/rf-observations", :operator),
        %{
          "session_id" => "survey-1"
        }
      )

    assert conn.status == 426
    assert Jason.decode!(conn.resp_body)["error"] == "websocket_required"
  end

  defp conn(path, role) do
    "GET"
    |> build_conn(path, nil)
    |> assign(:current_scope, %Scope{
      user: %{id: "user-1", role: role, status: :active},
      permissions: Catalog.permissions_for_role(role)
    })
  end
end
