defmodule ServiceRadarWebNGWeb.Api.DeviceBatchFactsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    device = device_fixture()

    %{conn: log_in_api_user(conn, user), user: user, device: device}
  end

  describe "PATCH /api/devices/metadata/batch" do
    test "writes facts to a single device successfully", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{
          "devices" => [%{"uid" => device.uid, "facts" => %{"nac_applied" => true}}]
        })
        |> json_response(200)

      assert [result] = response["results"]
      assert result["uid"] == device.uid
      assert result["status"] == "ok"
    end

    test "partial failure: one unknown uid does not affect others", %{conn: conn, device: device} do
      unknown_uid = "sr:device:test.fixture.unknown.abc"

      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{
          "devices" => [
            %{"uid" => device.uid, "facts" => %{"nac_applied" => true}},
            %{"uid" => unknown_uid, "facts" => %{"nac_applied" => true}}
          ]
        })
        |> json_response(200)

      results = response["results"]
      assert length(results) == 2

      ok_result = Enum.find(results, &(&1["uid"] == device.uid))
      assert ok_result["status"] == "ok"

      err_result = Enum.find(results, &(&1["uid"] == unknown_uid))
      assert err_result["status"] == "error"
      assert err_result["code"] == "device_not_found"
    end

    test "returns 400 when batch exceeds the size limit", %{conn: conn, device: device} do
      entries = Enum.map(1..1001, fn _ -> %{"uid" => device.uid, "facts" => %{"k" => "v"}} end)

      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{"devices" => entries})
        |> json_response(400)

      assert response["error"] =~ "1000"
    end

    test "returns 400 when devices key is missing", %{conn: conn} do
      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{"items" => []})
        |> json_response(400)

      assert response["error"] =~ "devices"
    end

    test "returns 400 when devices is not an array", %{conn: conn} do
      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{"devices" => "not_a_list"})
        |> json_response(400)

      assert response["error"] =~ "array"
    end

    test "invalid fact key returns per-device error, not 400", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/metadata/batch", %{
          "devices" => [%{"uid" => device.uid, "facts" => %{"InvalidKey" => true}}]
        })
        |> json_response(200)

      assert [result] = response["results"]
      assert result["uid"] == device.uid
      assert result["status"] == "error"
    end

    test "requires authentication", %{conn: conn, device: device} do
      conn
      |> delete_req_header("authorization")
      |> patch(~p"/api/devices/metadata/batch", %{
        "devices" => [%{"uid" => device.uid, "facts" => %{"a" => true}}]
      })
      |> json_response(401)
    end
  end
end
