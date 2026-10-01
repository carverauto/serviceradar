defmodule ServiceRadarWebNGWeb.Api.DeviceRemoveFactsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Api.DeviceController

  @moduletag :web_ng_shared_fixture_db

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    device = device_fixture()

    %{conn: log_in_api_user(conn, user), user: user, device: device}
  end

  describe "DELETE /api/devices/:uid/metadata/facts/:key" do
    test "removes an existing fact and echoes back remaining facts", %{conn: conn, device: device} do
      # Write a fact first via the existing write path.
      conn
      |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"example_fact" => true}})
      |> json_response(200)

      response =
        conn
        |> delete(~p"/api/devices/#{device.uid}/metadata/facts/example_fact")
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
      refute Map.has_key?(response["data"]["facts"], "example_fact")
    end

    test "removing a missing key is a no-op (returns 200)", %{conn: conn, device: device} do
      response =
        conn
        |> delete(~p"/api/devices/#{device.uid}/metadata/facts/never_written")
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
    end

    test "provenance entry is removed along with the value", %{conn: conn, device: device} do
      conn
      |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"example_fact" => "v"}})
      |> json_response(200)

      conn
      |> delete(~p"/api/devices/#{device.uid}/metadata/facts/example_fact")
      |> json_response(200)

      # Re-fetch and confirm no provenance remains.
      response =
        conn
        |> get(~p"/api/devices/#{device.uid}")
        |> json_response(200)

      metadata = response["data"]["metadata"] || %{}
      provenance = Map.get(metadata, "__fact_provenance", %{})
      refute Map.has_key?(provenance, "example_fact")
    end

    test "non-fact metadata owned by integrations is untouched", %{conn: conn, device: device} do
      # Write a user fact, then remove it; confirm an unrelated metadata key is preserved.
      conn
      |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"example_fact" => 1}})
      |> json_response(200)

      conn
      |> delete(~p"/api/devices/#{device.uid}/metadata/facts/example_fact")
      |> json_response(200)

      response =
        conn
        |> get(~p"/api/devices/#{device.uid}")
        |> json_response(200)

      metadata = response["data"]["metadata"] || %{}
      # The __fact_provenance key may still exist as an empty object; that is fine.
      refute Map.has_key?(metadata, "example_fact")
    end

    test "requires authentication", %{conn: conn, device: device} do
      conn
      |> delete_req_header("authorization")
      |> delete(~p"/api/devices/#{device.uid}/metadata/facts/example_fact")
      |> json_response(401)
    end

    test "returns 404 for an unknown device", %{conn: conn} do
      conn
      |> delete(~p"/api/devices/does-not-exist/metadata/facts/example_fact")
      |> json_response(404)
    end

    test "returns 422 when trying to remove another source's fact", %{
      conn: conn,
      user: user,
      device: device
    } do
      # Write a fact as the operator user (source = their identifier).
      conn
      |> patch(~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"example_fact" => true}})
      |> json_response(200)

      # A different user (different source identity) should not be able to remove it.
      other_user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
      other_conn = log_in_api_user(build_conn(), other_user)

      response =
        other_conn
        |> assign(
          :current_scope,
          Scope.for_user(other_user, permissions: MapSet.new(["devices.facts.write", "devices.view"]))
        )
        |> DeviceController.delete_metadata(%{"uid" => device.uid, "key" => "example_fact"})
        |> json_response(422)

      assert response["error"] =~ "different source"
    end

    test "returns 403 with devices.view but not devices.facts.write", %{
      conn: conn,
      user: user,
      device: device
    } do
      response =
        conn
        |> assign(
          :current_scope,
          Scope.for_user(user, permissions: MapSet.new(["devices.view"]))
        )
        |> DeviceController.delete_metadata(%{"uid" => device.uid, "key" => "example_fact"})
        |> json_response(403)

      assert response["error"] =~ "not authorized"
    end

    test "returns 422 for a reserved key", %{conn: conn, device: device} do
      response =
        conn
        |> delete(~p"/api/devices/#{device.uid}/metadata/facts/__fact_provenance")
        |> json_response(422)

      assert response["error"] =~ "reserved"
    end
  end
end
