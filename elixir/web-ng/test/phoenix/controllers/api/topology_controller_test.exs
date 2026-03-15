defmodule ServiceRadarWebNG.Api.TopologyControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian

  setup %{conn: conn} do
    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "POST /api/admin/topology/route-analysis" do
    test "returns deterministic route analysis", %{conn: conn} do
      params = %{
        "source_device_id" => "sr:router-a",
        "destination_ip" => "10.10.12.25",
        "routes_by_device" => %{
          "sr:router-a" => [
            %{
              "prefix" => "10.10.0.0/16",
              "next_hops" => [%{"target_device_id" => "sr:router-b", "next_hop_ip" => "10.0.0.2"}]
            }
          ],
          "sr:router-b" => [
            %{"prefix" => "10.10.12.0/24", "next_hops" => []}
          ]
        }
      }

      conn = post(conn, ~p"/api/admin/topology/route-analysis", params)
      result = json_response(conn, 200)["result"]

      assert result["status"] == "delivered"
      assert result["destination_ip"] == "10.10.12.25"
      assert result["start_device_id"] == "sr:router-a"
      assert result["terminal_device_id"] == "sr:router-b"
      assert is_list(result["hops"])
      assert length(result["hops"]) == 2
    end

    test "returns 400 when routes_by_device is missing", %{conn: conn} do
      params = %{
        "source_device_id" => "sr:router-a",
        "destination_ip" => "10.10.12.25"
      }

      conn = post(conn, ~p"/api/admin/topology/route-analysis", params)
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "routes_by_device"
    end

    test "returns 400 for invalid destination IPv4", %{conn: conn} do
      params = %{
        "source_device_id" => "sr:router-a",
        "destination_ip" => "not-an-ip",
        "routes_by_device" => %{"sr:router-a" => [%{"prefix" => "0.0.0.0/0", "next_hops" => []}]}
      }

      conn = post(conn, ~p"/api/admin/topology/route-analysis", params)
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "valid IPv4"
    end

    test "rejects viewer role", %{conn: _conn} do
      user = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(user)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/admin/topology/route-analysis", %{
          "source_device_id" => "sr:router-a",
          "destination_ip" => "10.10.12.25",
          "routes_by_device" => %{}
        })

      assert conn.status == 403
    end
  end
end
