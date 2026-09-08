defmodule ServiceRadarWebNGWeb.Api.ProxmoxConsoleSessionControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.ProxmoxConsoleSessionManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_open_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_close_result)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager,
      ProxmoxConsoleSessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(:proxmox_console_session_manager, previous_manager)
      restore_env(:proxmox_console_session_manager_open_result, previous_open_result)
      restore_env(:proxmox_console_session_manager_close_result, previous_close_result)
      restore_env(:proxmox_console_session_manager_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  describe "POST /api/proxmox/console-sessions" do
    test "creates a short-lived console session ticket", %{conn: conn} do
      conn =
        post(conn, ~p"/api/proxmox/console-sessions", %{
          "device_uid" => "pve-1",
          "terminal" => %{"cols" => 120, "rows" => 40}
        })

      body = json_response(conn, 201)

      assert body["data"]["device_uid"] == "pve-1"
      assert body["data"]["target_kind"] == "pve_host"
      assert body["data"]["console_mode"] == "ssh"
      assert body["data"]["ticket"] == "srpve_test_ticket_value"
      assert body["data"]["websocket_path"] =~ "/v1/proxmox/console-sessions/"
      refute body["data"]["websocket_path"] =~ "srpve_test_ticket_value"
      refute Map.has_key?(body["data"], "ticket_hash")

      assert_receive {:open_proxmox_console_session, "pve-1", request, opts}
      assert request.cols == 120
      assert request.rows == 40
      refute Map.has_key?(request, :target_kind)
      refute Map.has_key?(request, :console_mode)
      refute Map.has_key?(request, :credential_rule_id)
      refute Map.has_key?(request, :metadata)
      assert match?(%Scope{}, opts[:scope])
    end

    test "rejects browser-supplied target, mode, credential rule, and metadata", %{conn: conn} do
      conn =
        post(conn, ~p"/api/proxmox/console-sessions", %{
          "device_uid" => "pve-1",
          "target_kind" => "qemu_guest",
          "console_mode" => "proxmox_vncwebsocket",
          "credential_rule_id" => Ecto.UUID.generate(),
          "metadata" => %{"target" => %{"base_url" => "https://attacker.invalid"}}
        })

      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "unsupported fields"
      refute_receive {:open_proxmox_console_session, _device_uid, _request, _opts}
    end

    test "denies users without console permission", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/proxmox/console-sessions", %{"device_uid" => "pve-1"})

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "denies users with console-open but without credential-use permission", %{
      conn: conn,
      user: user
    } do
      put_test_permissions(user, ["devices.console.open"])

      conn = post(conn, ~p"/api/proxmox/console-sessions", %{"device_uid" => "pve-1"})

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:open_proxmox_console_session, _device_uid, _request, _opts}
    end

    test "returns 422 when no scoped console credential rule matches", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :proxmox_console_session_manager_open_result,
        {:error, :no_console_credential_rule}
      )

      conn = post(conn, ~p"/api/proxmox/console-sessions", %{"device_uid" => "pve-1"})
      body = json_response(conn, 422)

      assert body["error"] == "console_session_unavailable"
      assert body["message"] =~ "credential rule"
    end
  end

  describe "POST /api/proxmox/console-sessions/:id/close" do
    test "requests close without returning ticket material", %{conn: conn} do
      session_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/proxmox/console-sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)

      assert body["data"]["id"] == session_id
      assert body["data"]["status"] == "closing"
      assert body["data"]["close_reason"] == "operator_requested"
      refute Map.has_key?(body["data"], "ticket")
      refute Map.has_key?(body["data"], "ticket_hash")

      assert_receive {:close_proxmox_console_session, ^session_id, opts}
      assert opts[:reason] == "operator_requested"
      assert match?(%Scope{}, opts[:scope])
    end
  end

  describe "GET /v1/proxmox/console-sessions/:id/stream" do
    test "denies websocket upgrade without credential-use permission", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.console.open"])

      conn = get(conn, ~p"/v1/proxmox/console-sessions/#{Ecto.UUID.generate()}/stream")

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end
  end

  defp put_test_permissions(user, permissions) do
    Process.put({:rbac_permissions, user.id}, MapSet.new(permissions))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
