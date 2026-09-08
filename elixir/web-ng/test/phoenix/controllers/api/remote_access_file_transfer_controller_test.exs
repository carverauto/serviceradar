defmodule ServiceRadarWebNGWeb.Api.RemoteAccessFileTransferControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.RemoteAccessFileTransferManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :remote_access_file_transfer_manager)

    previous_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_file_transfer_manager_result)

    previous_list_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_file_transfer_manager_list_result)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :remote_access_file_transfer_manager_test_pid)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_file_transfer_manager,
      RemoteAccessFileTransferManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_file_transfer_manager_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(:remote_access_file_transfer_manager, previous_manager)
      restore_env(:remote_access_file_transfer_manager_result, previous_result)
      restore_env(:remote_access_file_transfer_manager_list_result, previous_list_result)
      restore_env(:remote_access_file_transfer_manager_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    auth_header = "Bearer #{token}"

    conn = Plug.Conn.put_req_header(conn, "authorization", auth_header)

    %{conn: conn, auth_header: auth_header}
  end

  describe "GET /api/remote-access/file-transfers" do
    test "lists transfer history for a session", %{conn: conn} do
      session_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/remote-access/file-transfers", %{"session_id" => session_id})

      body = json_response(conn, 200)

      assert [%{"session_id" => ^session_id, "operation" => "list", "status" => "completed"}] =
               body["data"]

      assert_receive {:remote_access_file_transfer_list, ^session_id, opts}
      assert match?(%Scope{}, opts[:scope])
    end

    test "requires list permission for transfer history" do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/remote-access/file-transfers", %{"session_id" => Ecto.UUID.generate()})

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:remote_access_file_transfer_list, _session_id, _opts}
    end
  end

  describe "POST /api/remote-access/file-transfers" do
    test "accepts bounded download intent without route or credential fields", %{conn: conn} do
      session_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/remote-access/file-transfers", %{
          "session_id" => session_id,
          "operation" => "download",
          "path" => "/var/log/syslog",
          "display_name" => "syslog"
        })

      body = json_response(conn, 202)

      assert body["data"]["session_id"] == session_id
      assert body["data"]["operation"] == "download"
      assert body["data"]["direction"] == "read"
      assert body["data"]["status"] == "requested"

      assert_receive {:remote_access_file_transfer, ^session_id, request, opts}
      assert request.operation == "download"
      assert request.direction == "read"
      assert request.path == "/var/log/syslog"
      assert request.display_name == "syslog"
      refute Map.has_key?(request, :agent_id)
      refute Map.has_key?(request, :gateway_id)
      refute Map.has_key?(request, :credential_rule_id)
      assert match?(%Scope{}, opts[:scope])
    end

    test "rejects browser-selected route, credential, target, policy, quota, and approval fields", %{
      auth_header: auth_header
    } do
      session_id = Ecto.UUID.generate()

      overrides = %{
        "agent_id" => "agent-from-browser",
        "gateway_id" => "gateway-from-browser",
        "target_host" => "10.0.0.10",
        "target_port" => 2222,
        "credential_rule_id" => Ecto.UUID.generate(),
        "credential_custody_mode" => "agent_local",
        "recording_policy" => %{"enabled" => false},
        "enhanced_recording_policy" => %{"enabled" => false},
        "quota" => %{"max_bytes" => 1},
        "approval_id" => Ecto.UUID.generate(),
        "ssh" => %{"username" => "root"}
      }

      for {field, value} <- overrides do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", auth_header)
          |> post(
            ~p"/api/remote-access/file-transfers",
            Map.put(
              %{
                "session_id" => session_id,
                "operation" => "download",
                "path" => "/var/log/syslog"
              },
              field,
              value
            )
          )

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ field
      end

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "rejects direction mismatch", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/file-transfers", %{
          "session_id" => Ecto.UUID.generate(),
          "operation" => "download",
          "direction" => "write",
          "path" => "/var/log/syslog"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "direction"
    end

    test "rejects unsafe source paths before dispatch", %{auth_header: auth_header} do
      session_id = Ecto.UUID.generate()

      for path <- ["/tmp/../etc/passwd", "/tmp/./syslog", "/tmp/" <> <<0>> <> "secret", "/tmp/\nsecret"] do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", auth_header)
          |> post(~p"/api/remote-access/file-transfers", %{
            "session_id" => session_id,
            "operation" => "download",
            "path" => path
          })

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ "path"
      end

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "rejects unsafe destination paths before dispatch", %{auth_header: auth_header} do
      session_id = Ecto.UUID.generate()

      for destination_path <- ["/tmp/../renamed", "/tmp/./renamed", "/tmp/" <> <<0>> <> "renamed"] do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", auth_header)
          |> post(~p"/api/remote-access/file-transfers", %{
            "session_id" => session_id,
            "operation" => "rename",
            "path" => "/tmp/source",
            "destination_path" => destination_path
          })

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ "destination_path"
      end

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "requires manage permission for mutating operations", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/remote-access/file-transfers", %{
          "session_id" => Ecto.UUID.generate(),
          "operation" => "remove",
          "path" => "/tmp/old"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "requires destination path for rename", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/file-transfers", %{
          "session_id" => Ecto.UUID.generate(),
          "operation" => "rename",
          "path" => "/tmp/a"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "destination_path"
    end

    test "refuses an upload with an empty path before dispatch", %{auth_header: auth_header} do
      session_id = Ecto.UUID.generate()

      for path <- ["", "   "] do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", auth_header)
          |> post(~p"/api/remote-access/file-transfers", %{
            "session_id" => session_id,
            "operation" => "upload",
            "path" => path
          })

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ "path"
      end

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "refuses an upload with a missing path before dispatch", %{auth_header: auth_header} do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> post(~p"/api/remote-access/file-transfers", %{
          "session_id" => Ecto.UUID.generate(),
          "operation" => "upload"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "path"

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end

    test "refuses a download with an empty path before dispatch", %{auth_header: auth_header} do
      session_id = Ecto.UUID.generate()

      for path <- ["", "   "] do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", auth_header)
          |> post(~p"/api/remote-access/file-transfers", %{
            "session_id" => session_id,
            "operation" => "download",
            "path" => path
          })

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ "path"
      end

      refute_receive {:remote_access_file_transfer, _session_id, _request, _opts}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
