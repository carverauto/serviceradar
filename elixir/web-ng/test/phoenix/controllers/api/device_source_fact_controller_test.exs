defmodule ServiceRadarWebNGWeb.Api.DeviceSourceFactControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers


  @moduletag :web_ng_shared_fixture_db

  @attachment %{"switch_hostname" => "access01.example.com", "port" => "Gi1/0/7", "vlan_id" => 120}

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    device = device_fixture()

    %{conn: log_in_api_user(conn, user), user: user, device: device}
  end

  defp put_fact(conn, device, fact_key, body) do
    put(conn, ~p"/api/devices/#{device.uid}/source-facts/#{fact_key}", body)
  end

  describe "PUT /api/devices/:uid/source-facts/:fact_key" do
    test "records the caller's value under its api source and promotes it", %{
      conn: conn,
      user: user,
      device: device
    } do
      data =
        conn
        |> put_fact(device, "switch_port_attachment", %{"source" => "example-nms", "value" => @attachment})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["uid"] == device.uid
      assert data["source"] == "api:example-nms"
      assert data["source_instance"] == "user:#{user.id}"
      assert data["reported"]["present"] == true
      assert data["reported"]["value"]["vlan_id"] == "120"
      assert {:ok, _observed_at, _offset} = DateTime.from_iso8601(data["reported"]["observed_at"])
      assert data["canonical"]["port"] == "Gi1/0/7"
      assert data["canonical"]["source"] == "api:example-nms"
      assert data["disagreement_open"] == false

      shown =
        conn
        |> get(~p"/api/devices/#{device.uid}")
        |> json_response(200)

      assert shown["data"]["switch_port_attachment"]["port"] == "Gi1/0/7"
    end

    test "requires authentication", %{conn: conn, device: device} do
      conn
      |> delete_req_header("authorization")
      |> put_fact(device, "switch_port_attachment", %{"source" => "example-nms", "value" => @attachment})
      |> json_response(401)
    end

    test "returns 404 for an unknown device", %{conn: conn} do
      response =
        conn
        |> put(~p"/api/devices/sr:#{Ecto.UUID.generate()}/source-facts/vlan_uid", %{
          "source" => "example-nms",
          "value" => 120
        })
        |> json_response(404)

      assert response["error"] == "device not found"
    end

    test "returns 400 when source or value is missing", %{conn: conn, device: device} do
      assert conn
             |> put_fact(device, "vlan_uid", %{"value" => 120})
             |> json_response(400)
             |> Map.fetch!("error") == "source is required"

      assert conn
             |> put_fact(device, "vlan_uid", %{"source" => "example-nms"})
             |> json_response(400)
             |> Map.fetch!("error") == "value is required"
    end

    test "returns 422 with the reason for an unreadable value or unknown key", %{
      conn: conn,
      device: device
    } do
      no_port =
        conn
        |> put_fact(device, "switch_port_attachment", %{
          "source" => "example-nms",
          "value" => %{"switch_hostname" => "access01.example.com"}
        })
        |> json_response(422)

      assert no_port["error"] =~ "switch_hostname and port"

      unknown =
        conn
        |> put_fact(device, "owner", %{"source" => "example-nms", "value" => "noc"})
        |> json_response(422)

      assert unknown["error"] =~ "switch_port_attachment, vlan_uid"

      bad_label =
        conn
        |> put_fact(device, "vlan_uid", %{"source" => "Example NMS", "value" => 120})
        |> json_response(422)

      assert bad_label["error"] =~ "source must be"
    end

    test "returns 403 with devices.view but not devices.source_facts.write", %{
      conn: conn,
      device: device
    } do
      viewer = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer})
      viewer_conn = log_in_api_user(build_conn(), viewer)

      response =
        viewer_conn
        |> put_fact(device, "vlan_uid", %{"source" => "example-nms", "value" => 120})
        |> json_response(403)

      assert response["error"] =~ "not authorized"

      shown = conn |> get(~p"/api/devices/#{device.uid}") |> json_response(200)
      assert shown["data"]["switch_port_attachment"] == nil
    end
  end

  describe "DELETE /api/devices/:uid/source-facts/:fact_key" do
    test "withdraws the caller's value and clears a canonical value nothing else reports", %{
      conn: conn,
      device: device
    } do
      conn
      |> put_fact(device, "switch_port_attachment", %{"source" => "example-nms", "value" => @attachment})
      |> json_response(200)

      data =
        conn
        |> delete(~p"/api/devices/#{device.uid}/source-facts/switch_port_attachment?source=example-nms")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["reported"]["present"] == false
      assert data["canonical"] == nil
    end

    test "withdrawing a fact that was never reported changes nothing", %{conn: conn, device: device} do
      data =
        conn
        |> delete(~p"/api/devices/#{device.uid}/source-facts/vlan_uid?source=example-nms")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["reported"] == nil
      assert data["canonical"] == nil
    end

    test "returns 400 without a source", %{conn: conn, device: device} do
      response =
        conn
        |> delete(~p"/api/devices/#{device.uid}/source-facts/vlan_uid")
        |> json_response(400)

      assert response["error"] == "source is required"
    end
  end
end
