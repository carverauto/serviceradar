defmodule ServiceRadarWebNGWeb.Api.FieldSurveyStreamControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian

  describe "FieldSurvey stream auth" do
    test "accepts ws_token on stream routes", %{conn: conn} do
      user = admin_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(user)

      conn =
        get(
          conn,
          "/v1/field-survey/#{Ecto.UUID.generate()}/rf-observations?" <>
            URI.encode_query(%{"ws_token" => token})
        )

      assert json_response(conn, 426)["error"] == "websocket_required"
    end

    test "does not accept ws_token on non-stream FieldSurvey routes", %{conn: conn} do
      user = admin_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(user)

      conn = get(conn, "/v1/field-survey/auth-check?" <> URI.encode_query(%{"ws_token" => token}))

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects stream routes without auth", %{conn: conn} do
      conn = get(conn, "/v1/field-survey/#{Ecto.UUID.generate()}/rf-observations")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
