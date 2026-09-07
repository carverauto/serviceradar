defmodule ServiceRadarWebNGWeb.Api.RemoteAccessSessionControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.RemoteAccessSessionManagerStub
  alias ServiceRadarWebNG.TestSupport.RemoteDesktopWebRTCSignalingManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :remote_access_session_manager)
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :remote_access_session_fetcher)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_open_result)

    previous_fetch_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_fetch_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_close_result)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :remote_access_session_manager_test_pid)

    previous_skip_verify =
      Application.get_env(:serviceradar_web_ng, :remote_access_ssh_host_key_skip_verify_enabled)

    previous_remote_access_ssh_enabled =
      Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)

    previous_remote_access_desktop_rdp_enabled =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    previous_remote_access_desktop_target_provider =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)

    previous_remote_access_desktop_targets =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_targets)

    previous_remote_access_desktop_webrtc_ice_servers =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers)

    previous_remote_access_desktop_webrtc_signaling_manager =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_signaling_manager)

    previous_remote_access_desktop_webrtc_test_pid =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_test_pid)

    previous_remote_access_desktop_webrtc_close_all_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_close_all_result)

    previous_target_host_override =
      Application.get_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled)

    previous_target_host_override_allowlist =
      Application.get_env(:serviceradar_web_ng, :remote_access_target_host_override_allowlist)

    previous_target_port_override =
      Application.get_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled)

    previous_device_visibility_fetcher =
      Application.get_env(:serviceradar_web_ng, :remote_access_device_visibility_fetcher)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager,
      RemoteAccessSessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      &RemoteAccessSessionManagerStub.get_by_id/2
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_manager_test_pid,
      self()
    )

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_signaling_manager,
      RemoteDesktopWebRTCSignalingManagerStub
    )

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_test_pid, self())

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_device_visibility_fetcher,
      fn device_uid, _opts -> {:ok, %ServiceRadar.Inventory.Device{uid: device_uid}} end
    )

    on_exit(fn ->
      restore_env(:remote_access_session_manager, previous_manager)
      restore_env(:remote_access_session_fetcher, previous_fetcher)
      restore_env(:remote_access_session_manager_open_result, previous_open_result)
      restore_env(:remote_access_session_manager_fetch_result, previous_fetch_result)
      restore_env(:remote_access_session_manager_close_result, previous_close_result)
      restore_env(:remote_access_session_manager_test_pid, previous_test_pid)
      restore_env(:remote_access_ssh_enabled, previous_remote_access_ssh_enabled)
      restore_env(:remote_access_desktop_rdp_enabled, previous_remote_access_desktop_rdp_enabled)
      restore_env(:remote_access_desktop_target_provider, previous_remote_access_desktop_target_provider)
      restore_env(:remote_access_desktop_targets, previous_remote_access_desktop_targets)
      restore_env(:remote_access_desktop_webrtc_ice_servers, previous_remote_access_desktop_webrtc_ice_servers)

      restore_env(
        :remote_access_desktop_webrtc_signaling_manager,
        previous_remote_access_desktop_webrtc_signaling_manager
      )

      restore_env(:remote_access_desktop_webrtc_test_pid, previous_remote_access_desktop_webrtc_test_pid)

      restore_env(
        :remote_access_desktop_webrtc_close_all_result,
        previous_remote_access_desktop_webrtc_close_all_result
      )

      restore_env(:remote_access_ssh_host_key_skip_verify_enabled, previous_skip_verify)
      restore_env(:remote_access_target_host_override_enabled, previous_target_host_override)
      restore_env(:remote_access_target_host_override_allowlist, previous_target_host_override_allowlist)
      restore_env(:remote_access_target_port_override_enabled, previous_target_port_override)
      restore_env(:remote_access_device_visibility_fetcher, previous_device_visibility_fetcher)
    end)

    user = admin_user_fixture()
    Process.put(:remote_access_test_user_id, user.id)
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  describe "GET /api/remote-access/devices/:device_uid/ssh-options" do
    test "returns browser-safe account names without principals", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_device_visibility_fetcher,
        fn device_uid, _opts -> {:ok, %{uid: device_uid}} end
      )

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_ssh_options_result,
        {:ok,
         %{
           "default_credential_mode" => "ssh_certificate",
           "accounts" => [%{"name" => "mfreeman"}, %{"name" => "deploy"}],
           "ttl_seconds" => 1800,
           "device_uid" => "linux-1"
         }}
      )

      conn = get(conn, ~p"/api/remote-access/devices/linux-1/ssh-options")
      body = json_response(conn, 200)

      assert body["data"]["default_credential_mode"] == "ssh_certificate"
      assert body["data"]["accounts"] == [%{"name" => "mfreeman"}, %{"name" => "deploy"}]
      assert body["data"]["ttl_seconds"] == 1800
      refute inspect(body) =~ "srp_v1_"
      refute inspect(body) =~ "principals"
      assert_receive {:ssh_console_options, "linux-1", opts}
      assert match?(%Scope{}, opts[:scope])
    end

    test "returns not found when SSH remote access is disabled", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)

      conn = get(conn, ~p"/api/remote-access/devices/linux-1/ssh-options")
      body = json_response(conn, 404)
      assert body["error"] == "not_found"
      refute_receive {:ssh_console_options, _device_uid, _opts}
    end
  end

  describe "POST /api/remote-access/sessions" do
    test "returns not found when SSH remote access is disabled", %{conn: conn} do
      Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh"
        })

      body = json_response(conn, 404)
      assert body["error"] == "not_found"
      assert body["message"] =~ "not enabled"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

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
            "ssh_host_key_approval" => %{
              "target" => "host01.example.com:22",
              "fingerprint" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
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
      refute Map.has_key?(body["data"], "desktop_webrtc_transport")
      refute inspect(body) =~ "must-not-return"

      assert_receive {:open_remote_access_session, "linux-1", request, opts}
      assert request.protocol == "ssh"
      assert request.adapter == "ssh"
      assert request.target_kind == "inventory_device"
      assert request.target_host == nil
      assert request.target_port == nil
      assert request.agent_id == nil
      assert request.gateway_id == nil
      assert request.credential_rule_id == nil
      assert request.approval_id == nil
      assert request.cols == 120
      assert request.rows == 40
      assert request.metadata["ssh_host_key_policy"] == "known_hosts"

      assert request.metadata["ssh_host_key_approval"] == %{
               "target" => "host01.example.com:22",
               "fingerprint" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
             }

      assert request.metadata["safe"] == "kept"
      assert request.metadata["nested"]["safe"] == "nested-kept"
      refute Map.has_key?(request.metadata, "private_key")
      refute Map.has_key?(request.metadata["nested"], "password")
      assert request.recording_policy == %{}
      assert request.enhanced_recording_policy == %{}
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

    test "creates an RDP session from an authorized desktop target without browser host overrides", %{
      conn: conn,
      user: user
    } do
      session_id = Ecto.UUID.generate()
      credential_rule_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [
        %{
          id: "desktop-target-1",
          label: "Finance Desktop",
          device_uid: "windows-1",
          target_host: "win-1.example.com",
          target_port: 3389,
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          credential_custody_mode: "centrally_brokered",
          credential_rule_id: credential_rule_id,
          approval_required: true,
          allowed_principals: ["  DOMAIN\\mfreeman  ", "DOMAIN\\mfreeman", "ops-admin"],
          target_tls: %{"mode" => "verify_ca", "password" => "must-not-forward"},
          nla: %{"required" => true},
          screen_policy: %{"max_width" => 1920, "max_height" => 1080},
          redirection_policy: %{"clipboard" => "disabled", "drive" => "disabled"},
          recording_policy: %{"mode" => "metadata_only"},
          metadata: %{
            "environment" => "prod",
            "rdp.kdc_proxy_url" => "tcp://kdc.policy.example.com:88",
            "rdp.kerberos_hostname" => "win-1.example.com",
            "secret" => "must-not-forward"
          }
        }
      ])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:ok,
         %{
           session:
             rdp_session(session_id,
               metadata: %{
                 "target_tls" => %{"mode" => "verify_ca"},
                 "nla" => %{"required" => true},
                 "screen_policy" => %{"max_width" => 1920, "max_height" => 1080},
                 "redirection_policy" => %{"clipboard" => "disabled", "drive" => "disabled"}
               },
               recording_policy: %{"mode" => "metadata_only"}
             ),
           ticket: "srra_rdp_ticket"
         }}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1",
          "metadata" => %{
            "allowed_principals" => ["browser-controlled"],
            "desktop_allowed_principals" => ["browser-controlled"],
            "client_trace_id" => "trace-1",
            "rdp.kdc_proxy_url" => "tcp://kdc.browser.example.com:88",
            "rdp.kerberos_hostname" => "browser.example.com",
            "target_tls" => %{"mode" => "skip_verify"},
            "screen_policy" => %{
              "max_width" => 99_999,
              "max_height" => 99_999,
              "frame_rate" => 999,
              "bitrate_bps" => 999_999_999
            },
            "nested" => %{"screen" => %{"max_width" => 99_999}},
            "password" => "must-not-forward"
          }
        })

      body = json_response(conn, 201)

      assert body["data"]["id"] == session_id
      assert body["data"]["protocol"] == "rdp"
      assert body["data"]["target_port"] == 3389
      assert body["data"]["ticket"] == "srra_rdp_ticket"
      assert body["data"]["desktop_policy_snapshot"]["desktop"]["target_tls"] == %{"mode" => "verify_ca"}
      refute inspect(body) =~ "must-not-forward"

      assert_receive {:open_remote_access_session, "windows-1", request, opts}
      assert request.protocol == "rdp"
      assert request.adapter == "rdp"
      assert request.target_kind == "inventory_device"
      assert request.target_host == "win-1.example.com"
      assert request.target_port == 3389
      assert request.agent_id == "agent-1"
      assert request.gateway_id == "gateway-1"
      assert request.credential_custody_mode == "centrally_brokered"
      assert request.credential_rule_id == credential_rule_id
      assert request.approval_required == true
      assert request.metadata["desktop_target_id"] == "desktop-target-1"
      assert request.metadata["target_display_name"] == "Finance Desktop"
      assert request.metadata["target_tls"] == %{"mode" => "verify_ca"}
      assert request.metadata["nla"] == %{"required" => true}

      assert request.metadata["screen_policy"] == %{
               "max_width" => 1920,
               "max_height" => 1080,
               "frame_rate" => 30,
               "bitrate_bps" => 8_000_000,
               "idle_seconds" => 900,
               "ttl_seconds" => 3600
             }

      refute get_in(request.metadata, ["nested", "screen"])
      assert request.metadata["redirection_policy"] == %{"clipboard" => "disabled", "drive" => "disabled"}
      assert request.metadata["environment"] == "prod"
      assert request.metadata["rdp.kdc_proxy_url"] == "tcp://kdc.policy.example.com:88"
      assert request.metadata["rdp.kerberos_hostname"] == "win-1.example.com"
      assert request.metadata["client_trace_id"] == "trace-1"
      assert request.metadata["desktop_allowed_principals"] == ["DOMAIN\\mfreeman", "ops-admin"]
      refute Map.has_key?(request.metadata, "password")
      refute Map.has_key?(request.metadata, "secret")
      assert request.recording_policy == %{"mode" => "metadata_only"}
      assert match?(%Scope{}, opts[:scope])
    end

    test "materializes bounded screen defaults when target policy is empty", %{
      conn: conn,
      user: user
    } do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [desktop_target()])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_open_result,
        {:ok, %{session: rdp_session(session_id), ticket: "srra_rdp_default_ticket"}}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1",
          "metadata" => %{
            "screen_policy" => %{
              "max_width" => 99_999,
              "max_height" => 99_999,
              "frame_rate" => 999,
              "bitrate_bps" => 999_999_999,
              "idle_seconds" => 999_999,
              "ttl_seconds" => 999_999
            }
          }
        })

      assert json_response(conn, 201)["data"]["id"] == session_id
      assert_receive {:open_remote_access_session, "windows-1", request, _opts}

      assert request.metadata["screen_policy"] == %{
               "max_width" => 1920,
               "max_height" => 1080,
               "frame_rate" => 30,
               "bitrate_bps" => 8_000_000,
               "idle_seconds" => 900,
               "ttl_seconds" => 3600
             }
    end

    test "returns not found for RDP create when desktop access is disabled", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 404)
      assert body["error"] == "not_found"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects an RDP launch when the browser device does not exactly match the target", %{
      conn: conn,
      user: user
    } do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [desktop_target()])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-2",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_desktop_target_not_found"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects an RDP launch when the target device is not visible to the user", %{
      conn: conn,
      user: user
    } do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [desktop_target()])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_device_visibility_fetcher,
        fn _device_uid, _opts -> {:error, :not_found} end
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_desktop_target_not_found"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects a disabled static RDP target", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [
        desktop_target(%{enabled: false})
      ])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_desktop_target_not_found"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects a disabled RDP target returned by a custom provider", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_desktop_target_provider,
        fn _scope, _opts -> {:ok, [desktop_target(%{enabled: false})]} end
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_desktop_target_not_found"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "requires RDP permission before creating RDP sessions", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.ssh.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects browser-selected RDP target host and port overrides", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "windows-1",
          "protocol" => "rdp",
          "desktop_target_id" => "desktop-target-1",
          "target_host" => "browser.example.com",
          "target_port" => 3390
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_host"
      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
    end

    test "rejects RDP create without a registered desktop target", %{conn: conn, user: user} do
      put_test_permissions(user, ["devices.remote_access.rdp.open"])
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "rdp"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "desktop_target_id"
    end

    test "rejects future app and tcp protocols on the public SSH endpoint", %{conn: conn} do
      for protocol <- ["app", "tcp"] do
        conn =
          post(conn, ~p"/api/remote-access/sessions", %{
            "device_uid" => "linux-1",
            "protocol" => protocol
          })

        body = json_response(conn, 400)
        assert body["error"] == "invalid_request"
        assert body["message"] =~ "protocol"
      end

      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
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

    test "rejects browser-selected credential rules", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_rule_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "credential_rule_id"
    end

    test "rejects invalid approval ids before session creation", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "approval_id" => "not-a-uuid"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "approval_id"
    end

    test "rejects malformed terminal dimensions", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "terminal" => %{"cols" => 10_000, "rows" => 40}
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "terminal.cols"
    end

    test "rejects non-object terminal payloads", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "terminal" => "120x40"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "terminal"
    end

    test "rejects browser-selected recording policy", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "recording_policy" => %{"enabled" => false}
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "recording_policy"
    end

    test "rejects browser-selected enhanced recording policy", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "enhanced_recording_policy" => %{"enabled" => false}
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "enhanced_recording_policy"
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

    test "rejects target port override without explicit override permission", %{conn: conn, user: user} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled, true)
      put_test_permissions(user, ["devices.remote_access.ssh.open"])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_port" => 2222
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:open_remote_access_session, "linux-1", _request, _opts}
    end

    test "allows target port override when deployment and RBAC explicitly enable it", %{conn: conn, user: user} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled, true)

      put_test_permissions(user, [
        "devices.remote_access.ssh.open",
        "devices.remote_access.ssh.target.override"
      ])

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

    test "rejects invalid target port overrides when deployment explicitly enables them", %{
      conn: conn,
      user: user
    } do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_port_override_enabled, true)

      put_test_permissions(user, [
        "devices.remote_access.ssh.open",
        "devices.remote_access.ssh.target.override"
      ])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_port" => 70_000
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_port"
    end

    test "rejects target host override without explicit override permission", %{conn: conn, user: user} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_allowlist, ["10.0.0.10"])
      put_test_permissions(user, ["devices.remote_access.ssh.open"])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_host" => "10.0.0.10"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:open_remote_access_session, "linux-1", _request, _opts}
    end

    test "rejects target host override when host is not allowlisted", %{conn: conn, user: user} do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_allowlist, ["allowed.example.com"])

      put_test_permissions(user, [
        "devices.remote_access.ssh.open",
        "devices.remote_access.ssh.target.override"
      ])

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "protocol" => "ssh",
          "target_host" => "10.0.0.10"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "allowlisted"
      refute_receive {:open_remote_access_session, "linux-1", _request, _opts}
    end

    test "allows target host override when deployment, RBAC, and allowlist explicitly enable it", %{
      conn: conn,
      user: user
    } do
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_enabled, true)
      Application.put_env(:serviceradar_web_ng, :remote_access_target_host_override_allowlist, ["10.0.0.10"])

      put_test_permissions(user, [
        "devices.remote_access.ssh.open",
        "devices.remote_access.ssh.target.override"
      ])

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
            "accounts" => [%{"name" => "root", "principals" => ["client-controlled"]}],
            "ssh_accounts" => [%{"name" => "root", "principals" => ["client-controlled"]}],
            "ssh_allowed_principals" => ["root"],
            "allowed_principals" => ["root"],
            "principals" => ["root"],
            "requested_principals" => ["root"],
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
            accounts
            ssh_accounts
            ssh_allowed_principals
            allowed_principals
            principals
            requested_principals
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

    test "strips client-controlled application and TCP target policy metadata", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "metadata" => %{
            "safe" => "kept",
            "application_id" => "app-from-browser",
            "app_target_id" => "target-from-browser",
            "tcp_target_id" => "tcp-from-browser",
            "upstream_host" => "169.254.169.254",
            "upstream_port" => 80,
            "upstream_url" => "http://169.254.169.254/latest/meta-data",
            "url" => "http://169.254.169.254/",
            "route_id" => "agent-route-from-browser",
            "host_header" => "metadata.google.internal",
            "sni" => "metadata.google.internal",
            "tls_server_name" => "metadata.google.internal",
            "ca_bundle_ref" => "browser-ca",
            "allowed_methods" => ["GET", "POST"],
            "allowed_path_prefixes" => ["/"],
            "max_request_bytes" => 1_000_000_000,
            "max_response_bytes" => 1_000_000_000,
            "recording" => %{"enabled" => false},
            "quota" => %{"bytes" => 1_000_000_000}
          }
        })

      assert json_response(conn, 201)
      assert_receive {:open_remote_access_session, "linux-1", request, _opts}

      assert request.metadata["safe"] == "kept"

      for key <- ~w(
            application_id
            app_target_id
            tcp_target_id
            upstream_host
            upstream_port
            upstream_url
            url
            route_id
            host_header
            sni
            tls_server_name
            ca_bundle_ref
            allowed_methods
            allowed_path_prefixes
            max_request_bytes
            max_response_bytes
            recording
            quota
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

    test "rejects browser-selected policy-owned custody modes through the generic API", %{conn: conn} do
      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_custody_mode" => "agent_local"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "credential_custody_mode"

      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}

      conn =
        post(conn, ~p"/api/remote-access/sessions", %{
          "device_uid" => "linux-1",
          "credential_custody_mode" => "centrally_brokered"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "credential_custody_mode"

      refute_receive {:open_remote_access_session, _device_uid, _request, _opts}
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
      assert body["message"] =~ "trusted account and principal policy"
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
          "credential_custody_mode" => "ssh_certificate",
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
          "credential_custody_mode" => "ssh_certificate",
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

    test "returns desktop WebRTC metadata for RDP sessions", %{conn: conn} do
      session_id = Ecto.UUID.generate()

      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_ice_servers,
        [%{urls: ["stun:stun.example.com:3478"]}]
      )

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id)}
      )

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_close_result,
        {:ok, rdp_session(session_id, status: :closing, close_reason: "operator_requested")}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)

      assert body["data"]["protocol"] == "rdp"
      assert body["data"]["target_port"] == 3389
      assert body["data"]["desktop_webrtc_enabled"] == true
      assert body["data"]["desktop_webrtc_transport"] == "webrtc_desktop_media"

      assert body["data"]["desktop_webrtc_signaling_path"] ==
               "/api/remote-access/sessions/#{session_id}/webrtc/session"

      assert body["data"]["desktop_webrtc_ice_servers"] == []
      refute Map.has_key?(body["data"], "ticket")
    end

    test "does not reveal or close an RDP session owned by another user", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id, requested_by: Ecto.UUID.generate())}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_session_not_found"
      refute_receive {:close_remote_access_session, ^session_id, _opts}
      refute_receive {:desktop_webrtc_close_all_for_session, ^session_id, _opts}
    end

    test "requires RDP permission before closing RDP sessions", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.ssh.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id)}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      refute_receive {:close_remote_access_session, ^session_id, _opts}
      refute_receive {:desktop_webrtc_close_all_for_session, ^session_id, _opts}
    end

    test "allows RDP close with RDP permission without SSH permission", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id)}
      )

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_close_result,
        {:ok, rdp_session(session_id, status: :closing, close_reason: "operator_requested")}
      )

      conn =
        post(conn, ~p"/api/remote-access/sessions/#{session_id}/close", %{
          "reason" => "operator_requested"
        })

      body = json_response(conn, 200)
      assert body["data"]["protocol"] == "rdp"
      assert body["data"]["status"] == "closing"
      assert_receive {:close_remote_access_session, ^session_id, _opts}
      assert_receive {:desktop_webrtc_close_all_for_session, ^session_id, opts}
      assert opts[:actor_id] == user.id
      assert opts[:reason] == "operator_requested"
      refute Keyword.has_key?(opts, :scope)
    end
  end

  describe "GET /api/remote-access/sessions/:id" do
    test "does not reveal a session owned by another user", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id, requested_by: Ecto.UUID.generate())}
      )

      conn = get(conn, ~p"/api/remote-access/sessions/#{session_id}")

      body = json_response(conn, 404)
      assert body["error"] == "remote_access_session_not_found"
    end

    test "requires protocol-specific permission for RDP sessions", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.ssh.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok, rdp_session(session_id)}
      )

      conn = get(conn, ~p"/api/remote-access/sessions/#{session_id}")

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "returns a sanitized desktop policy snapshot for RDP sessions", %{conn: conn, user: user} do
      session_id = Ecto.UUID.generate()
      credential_rule_id = Ecto.UUID.generate()
      put_test_permissions(user, ["devices.remote_access.rdp.open"])

      Application.put_env(
        :serviceradar_web_ng,
        :remote_access_session_manager_fetch_result,
        {:ok,
         rdp_session(session_id,
           credential_rule_id: credential_rule_id,
           metadata: %{
             "target_display_name" => "Finance jump desktop",
             "target_tls" => %{"mode" => "verify_ca", "password" => "must-not-return"},
             "nla_policy" => %{"required" => true, "private_key" => "must-not-return"},
             "screen_policy" => %{"max_frame_rate" => 30, "max_width" => 1920, "max_height" => 1080},
             "redirection_policy" => %{"clipboard" => "disabled", "drive" => "disabled"},
             "approval_policy" => %{"required" => true, "token" => "must-not-return"}
           },
           recording_policy: %{"mode" => "metadata", "secret" => "must-not-return"},
           enhanced_recording_policy: %{"enabled" => false, "private_key" => "must-not-return"}
         )}
      )

      conn = get(conn, ~p"/api/remote-access/sessions/#{session_id}")

      body = json_response(conn, 200)
      snapshot = body["data"]["desktop_policy_snapshot"]

      assert snapshot["target"]["display_name"] == "Finance jump desktop"
      assert snapshot["target"]["device_uid"] == "windows-1"
      assert snapshot["route"] == %{"agent_id" => "agent-1", "gateway_id" => "gateway-1"}
      assert snapshot["credential"]["custody_mode"] == "user_present"
      assert snapshot["credential"]["brokered_rule_bound"] == true
      assert snapshot["authorization"]["rbac_decision"] == "allowed"
      assert snapshot["timeouts"]["idle_timeout_seconds"] == 900
      assert snapshot["desktop"]["target_tls"] == %{"mode" => "verify_ca"}
      assert snapshot["desktop"]["nla"] == %{"required" => true}
      assert snapshot["desktop"]["screen_policy"]["max_frame_rate"] == 30
      assert snapshot["desktop"]["redirection_policy"] == %{"clipboard" => "disabled", "drive" => "disabled"}
      assert snapshot["desktop"]["approval_policy"] == %{"required" => true}
      assert snapshot["recording"]["policy"] == %{"mode" => "metadata"}
      assert snapshot["recording"]["enhanced_policy"] == %{"enabled" => false}
      refute inspect(body) =~ "must-not-return"
    end
  end

  defp rdp_session(session_id, attrs \\ []) do
    struct!(
      RemoteAccessSession,
      Keyword.merge(
        [
          id: session_id,
          device_uid: "windows-1",
          target_kind: :inventory_device,
          target_host: "windows-1.example.com",
          target_port: 3389,
          protocol: :rdp,
          adapter: :rdp,
          agent_id: "agent-1",
          gateway_id: "gateway-1",
          credential_custody_mode: :user_present,
          requested_by: Process.get(:remote_access_test_user_id),
          status: :active,
          rbac_decision: :allowed,
          attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          idle_timeout_seconds: 900,
          absolute_timeout_seconds: 3600,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ],
        attrs
      )
    )
  end

  defp desktop_target(attrs \\ %{}) do
    Map.merge(
      %{
        id: "desktop-target-1",
        enabled: true,
        label: "Test desktop",
        device_uid: "windows-1",
        target_host: "windows-1.example.com",
        target_port: 3389,
        agent_id: "agent-1",
        gateway_id: "gateway-1"
      },
      attrs
    )
  end

  defp put_test_permissions(user, permissions) do
    Process.put({:rbac_permissions, user.id}, MapSet.new(permissions))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
