defmodule ServiceRadarWebNGWeb.Api.RemoteAccessSessionControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.RemoteAccessSessionManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :remote_access_session_manager)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_open_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_close_result)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      RemoteAccessSessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(:remote_access_session_manager, previous_manager)
      restore_env(:remote_access_session_manager_open_result, previous_open_result)
      restore_env(:remote_access_session_manager_close_result, previous_close_result)
      restore_env(:remote_access_session_manager_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "POST /api/remote-access/sessions" do
    test "creates a generic SSH session ticket without credential material in the response", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_host" => "10.0.0.10",
          "target_port" => 2222,
          "credential_custody_mode" => "ssh_certificate",
          "terminal" => %{"cols" => 120, "rows" => 40},
          "metadata" => %{"private_key" => "must-not-return", "safe" => "kept"}
        })

      body = json_response(conn, 201)

      assert body["data"]["device_uid"] == "linux-1"
      assert body["data"]["protocol"] == "ssh"
      assert body["data"]["target_host"] == "10.0.0.10"
      assert body["data"]["target_port"] == 2222
      assert body["data"]["credential_custody_mode"] == "ssh_certificate"
      assert body["data"]["ticket"] == "srra_test_ticket_value"
      assert body["data"]["websocket_path"] =~ "/v1/remote-access/sessions/"
      refute body["data"]["websocket_path"] =~ "srra_test_ticket_value"
      refute Map.has_key?(body["data"], "attach_ticket_hash")
      refute inspect(body) =~ "must-not-return"

      assert_receive {:open_remote_access_session, "linux-1", request, opts}
      assert request.protocol == "ssh"
      assert request.target_host == "10.0.0.10"
      assert request.target_port == 2222
      assert request.cols == 120
      assert request.rows == 40
      assert request.metadata["private_key"] == "must-not-return"
      assert match?(%Scope{}, opts[:scope])
    end

    test "denies users without remote-access permission", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/remote-access/sessions", %{"device_uid" => "linux-1"})

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "rejects agent-local custody through the generic API", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:error, :unsupported_credential_custody_mode}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_custody_mode" => "agent_local"
        })

      body = json_response(conn, 422)
      assert body["error"] == "remote_access_session_unavailable"
      assert body["message"] =~ "custody mode"
    end

    test "maps approval-required policy denials without issuing a ticket", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:error, :approval_required}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_custody_mode" => "centrally_brokered",
          "approval_required" => true
        })

      body = json_response(conn, 403)
      assert body["error"] == "approval_required"
      refute inspect(body) =~ "ticket"
    end
  end

  describe "POST /api/remote-access/sessions/:id/close" do
    test "requests close without returning ticket material", %{conn: conn} do
      session_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/remote-access/sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)

      assert body["data"]["id"] == session_id
      assert body["data"]["status"] == "closing"
      assert body["data"]["close_reason"] == "operator_requested"
      refute Map.has_key?(body["data"], "ticket")
      refute Map.has_key?(body["data"], "attach_ticket_hash")

      assert_receive {:close_remote_access_session, ^session_id, opts}
      assert opts[:reason] == "operator_requested"
      assert match?(%Scope{}, opts[:scope])
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
