defmodule ServiceRadarWebNGWeb.Api.DeviceFactsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.DeviceController

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    device = device_fixture()

    %{conn: log_in_api_user(conn, user), user: user, device: device}
  end

  describe "PATCH /api/devices/:uid/metadata" do
    test "writes a fact and echoes it back with provenance", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"nac_applied" => true}})
        |> json_response(200)

      assert response["data"]["uid"] == device.uid

      fact = response["data"]["facts"]["nac_applied"]
      assert fact["value"] == true
      assert is_binary(fact["source"])
      assert {:ok, _dt, _} = DateTime.from_iso8601(fact["updated_at"])
    end

    test "requires authentication", %{conn: conn, device: device} do
      conn
      |> delete_req_header("authorization")
      |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"a" => true}})
      |> json_response(401)
    end

    test "returns 404 for an unknown device", %{conn: conn} do
      response =
        conn
        |> patch(~p"/api/devices/does-not-exist/metadata", %{"facts" => %{"a" => true}})
        |> json_response(404)

      assert response["error"] == "device not found"
    end

    test "returns 400 when facts is missing or malformed", %{conn: conn, device: device} do
      assert conn
             |> patch(~p"/api/devices/#{device.uid}/metadata", %{})
             |> json_response(400)

      assert conn
             |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => "nope"})
             |> json_response(400)

      assert conn
             |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{}})
             |> json_response(400)
    end

    test "returns 422 naming the offending key", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"NacApplied" => true}})
        |> json_response(422)

      assert response["error"] =~ "NacApplied"
    end

    test "returns 422 for a non-scalar value", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/#{device.uid}/metadata", %{
          "facts" => %{"nested" => %{"a" => 1}}
        })
        |> json_response(422)

      assert response["error"] =~ "scalar"
    end

    test "returns 422 for a reserved key", %{conn: conn, device: device} do
      response =
        conn
        |> patch(~p"/api/devices/#{device.uid}/metadata", %{
          "facts" => %{"passive_fingerprint" => true}
        })
        |> json_response(422)

      assert response["error"] =~ "reserved"
    end

    test "returns 403 with devices.view but not devices.facts.write", %{
      conn: conn,
      user: user,
      device: device
    } do
      # devices.view is granted so the lookup succeeds and the write is what
      # gets refused. This is the separation that matters: a validation tool can
      # be allowed to read a device without being allowed to mutate it.
      response =
        conn
        |> assign(
          :current_scope,
          Scope.for_user(user, permissions: MapSet.new(["devices.view"]))
        )
        |> DeviceController.update_metadata(%{
          "uid" => device.uid,
          "facts" => %{"nac_applied" => true}
        })
        |> json_response(403)

      assert response["error"] =~ "not authorized"
    end

    test "echoes only externally written facts, not internal metadata", %{
      conn: conn,
      device: device
    } do
      # A caller holding only devices.facts.write should not learn the device's
      # internal enrichment through the response body.
      response =
        conn
        |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"nac_applied" => true}})
        |> json_response(200)

      assert Map.keys(response["data"]["facts"]) == ["nac_applied"]
    end
  end
end
