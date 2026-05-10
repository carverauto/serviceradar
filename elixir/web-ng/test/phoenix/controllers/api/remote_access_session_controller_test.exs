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

    previous_skip_verify =
      Application.get_env(:serviceradar_web_ng, :remote_access_ssh_host_key_skip_verify_enabled)

    previous_target_host_override =
      Application.get_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled)

    previous_target_port_override =
      Application.get_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled)

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
      restore_env(:remote_access_ssh_host_key_skip_verify_enabled, previous_skip_verify)
      restore_env(:remote_access_target_host_override_enabled, previous_target_host_override)
      restore_env(:remote_access_target_port_override_enabled, previous_target_port_override)
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
          "credential_custody_mode" => "ssh_certificate",
          "ssh_host_key_policy" => "known_hosts",
          "terminal" => %{"cols" => 120, "rows" => 40},
          "metadata" => %{
            "private_key" => "must-not-return",
            "nested" => %{"password" => "must-not-forward", "safe" => "nested-kept"},
            "safe" => "kept"
          }
        })

      body = json_response(conn, 201)

      assert body["data"]["device_uid"] == "linux-1"
      assert body["data"]["protocol"] == "ssh"
      assert body["data"]["target_port"] == 22
      assert body["data"]["credential_custody_mode"] == "ssh_certificate"
      assert body["data"]["ticket"] == "srra_test_ticket_value"
      assert body["data"]["websocket_path"] =~ "/v1/remote-access/sessions/"
      refute body["data"]["websocket_path"] =~ "srra_test_ticket_value"
      refute Map.has_key?(body["data"], "attach_ticket_hash")
      refute inspect(body) =~ "must-not-return"

      assert_receive {:open_remote_access_session, "linux-1", request, opts}
      assert request.protocol == "ssh"
      assert request.adapter == "ssh"
      assert request.target_kind == "inventory_device"
      assert request.target_host == nil
      assert request.target_port == nil
      assert request.agent_id == nil
      assert request.gateway_id == nil
      assert request.cols == 120
      assert request.rows == 40
      assert request.metadata["ssh_host_key_policy"] == "known_hosts"
      assert request.metadata["safe"] == "kept"
      assert request.metadata["nested"]["safe"] == "nested-kept"
      refute Map.has_key?(request.metadata, "private_key")
      refute Map.has_key?(request.metadata["nested"], "password")
      assert match?(%Scope{}, opts[:scope])
    end

    test "defaults the public create API to SSH inventory sessions", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1"
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}
      assert request.protocol == "ssh"
      assert request.adapter == "ssh"
      assert request.target_kind == "inventory_device"
    end

    test "rejects non-SSH protocols on the public SSH endpoint", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "rdp"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "protocol"
    end

    test "rejects non-SSH adapters on the public SSH endpoint", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "adapter" => "proxmox_console"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "adapter"
    end

    test "rejects non-inventory target kinds on the public SSH endpoint", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "target_kind" => "provider_console"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_kind"
    end

    test "rejects browser-selected agent routes", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "agent_id" => "agent-from-browser"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "agent_id"
    end

    test "rejects browser-selected gateway routes", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "gateway_id" => "gateway-from-browser"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "gateway_id"
    end

    test "rejects target host override unless deployment allows it", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_host" => "10.0.0.10"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_host"
    end

    test "rejects target port override unless deployment allows it", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_port" => 2222
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_port"
    end

    test "allows target port override when deployment explicitly enables it", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled, true)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_port" => 2222
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}
      assert request.target_port == 2222
    end

    test "allows target host override when deployment explicitly enables it", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled, true)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_host" => "10.0.0.10"
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}
      assert request.target_host == "10.0.0.10"
    end

    test "rejects skip-verify SSH host key policy unless deployment allows it", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "ssh_host_key_policy" => "skip_verify"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "ssh_host_key_policy"
    end

    test "allows skip-verify SSH host key policy when deployment explicitly enables it", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_ssh_host_key_skip_verify_enabled,
        true
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "ssh_host_key_policy" => "skip_verify"
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}
      assert request.metadata["ssh_host_key_policy"] == "skip_verify"
    end

    test "rejects unsupported SSH host key policies", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "ssh_host_key_policy" => "accept_anything"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "ssh_host_key_policy"
    end

    test "rejects unsupported SSH host key policies from metadata", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "metadata" => %{"ssh_host_key_policy" => "accept_anything"}
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "ssh_host_key_policy"
    end

    test "strips client-controlled SSH certificate policy metadata", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "credential_custody_mode" => "ssh_certificate",
          "metadata" => %{
            "safe" => "kept",
            "ssh_host_key_policy" => "known_hosts",
            "ssh_allowed_principals" => ["root"],
            "allowed_principals" => ["root"],
            "ssh_principal_mappings" => [
              %{"source" => "groups", "value" => "admins", "principals" => ["root"]}
            ],
            "principal_mappings" => [
              %{"source" => "groups", "value" => "admins", "principals" => ["root"]}
            ],
            "ssh_certificate_ttl_seconds" => 28_800,
            "credential_mode" => "ssh_certificate",
            "credential_custody_mode" => "ssh_certificate",
            "ssh" => %{"username" => "root"},
            "ssh_certificate" => %{"ssh" => %{"certificate" => "client-controlled"}},
            "certificate_envelope" => %{"ssh" => %{"certificate" => "client-controlled"}}
          }
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}

      assert request.metadata["safe"] == "kept"
      assert request.metadata["ssh_host_key_policy"] == "known_hosts"

      for key <- ~w(
            ssh_allowed_principals
            allowed_principals
            ssh_principal_mappings
            principal_mappings
            ssh_certificate_ttl_seconds
            credential_mode
            credential_custody_mode
            ssh
            ssh_certificate
            certificate_envelope
          ) do
        refute Map.has_key?(request.metadata, key)
      end
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

    test "rejects SSH certificate sessions when trusted principal policy is missing", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:error, :ssh_principal_policy_required}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "credential_custody_mode" => "ssh_certificate"
        })

      body = json_response(conn, 422)
      assert body["error"] == "remote_access_session_unavailable"
      assert body["message"] =~ "trusted principal policy"
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

    test "maps missing approval verifier without issuing a ticket", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:error, :approval_checker_required}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_custody_mode" => "centrally_brokered",
          "approval_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 403)
      assert body["error"] == "approval_checker_required"
      assert body["message"] =~ "verified"
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
