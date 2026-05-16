defmodule ServiceRadarWebNGWeb.Api.RemoteAccessDesktopTargetControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessDesktopTarget
  alias ServiceRadarWebNG.Auth.Guardian

  setup %{conn: conn} do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)
    previous_provider = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)
    previous_targets = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_targets)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous_enabled)
      restore_env(:remote_access_desktop_target_provider, previous_provider)
      restore_env(:remote_access_desktop_targets, previous_targets)
    end)

    user = admin_user_fixture()
    put_test_permissions(user, ["devices.remote_access.rdp.open"])

    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "lists authorized RDP desktop targets without credential material", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_target_provider,
      fn scope, opts ->
        send(self(), {:desktop_target_list, scope, opts})

        {:ok,
         [
           %{
             "id" => "target-1",
             "label" => "Windows Jump Box",
             "device_uid" => "windows-1",
             "target_host" => "win-1.example.com",
             "target_port" => "3389",
             "agent_id" => "agent-1",
             "gateway_id" => "gateway-1",
             "credential_custody_mode" => "user_present",
             "approval_required" => true,
             "target_tls" => %{"mode" => "verify_ca", "password" => "must-not-return"},
             "nla" => %{"required" => true, "token" => "must-not-return"},
             "screen_policy" => %{"max_width" => 1920, "max_height" => 1080, "secret" => "drop"},
             "redirection_policy" => %{
               "clipboard" => "disabled",
               "drive" => "disabled",
               "private_key" => "drop"
             },
             "recording_policy" => %{"mode" => "metadata_only", "api_key" => "drop"},
             "metadata" => %{
               "environment" => "lab",
               "password" => "must-not-return",
               "nested" => %{"safe" => "kept", "secret_token" => "drop"},
               "target_tls" => %{"mode" => "ignored"}
             }
           }
         ]}
      end
    )

    conn = get(conn, ~p"/api/remote-access/desktop-targets")
    body = json_response(conn, 200)

    assert_receive {:desktop_target_list, scope, _opts}
    assert scope.user

    assert [
             %{
               "id" => "target-1",
               "label" => "Windows Jump Box",
               "device_uid" => "windows-1",
               "target_host" => "win-1.example.com",
               "target_port" => 3389,
               "protocol" => "rdp",
               "adapter" => "rdp",
               "credential_custody_mode" => "user_present",
               "approval_required" => true,
               "route" => %{"agent_id" => "agent-1", "gateway_id" => "gateway-1"},
               "desktop_policy" => desktop_policy,
               "recording_policy" => %{"mode" => "metadata_only"},
               "metadata" => metadata
             }
           ] = body["data"]

    assert desktop_policy["target_tls"] == %{"mode" => "verify_ca"}
    assert desktop_policy["nla"] == %{"required" => true}
    assert desktop_policy["screen_policy"] == %{"max_width" => 1920, "max_height" => 1080}
    assert desktop_policy["redirection_policy"] == %{"clipboard" => "disabled", "drive" => "disabled"}
    assert metadata == %{"environment" => "lab", "nested" => %{"safe" => "kept"}}

    refute conn.resp_body =~ "must-not-return"
    refute conn.resp_body =~ "drop"
  end

  test "uses static configured targets when no provider is configured", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [
      %{id: "target-1", target_host: "win-1.example.com"}
    ])

    conn = get(conn, ~p"/api/remote-access/desktop-targets")
    body = json_response(conn, 200)

    assert [%{"id" => "target-1", "target_port" => 3389, "protocol" => "rdp"}] = body["data"]
  end

  test "lists persisted registered targets when no provider or static config is configured", %{conn: conn} do
    Application.delete_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)
    Application.delete_env(:serviceradar_web_ng, :remote_access_desktop_targets)

    target_name = "Finance Desktop #{System.unique_integer([:positive])}"

    assert {:ok, target} =
             RemoteAccessDesktopTarget.create_target(
               %{
                 name: target_name,
                 device_uid: "windows-resource-1",
                 target_host: "win-resource-1.example.com",
                 target_port: 3389,
                 agent_id: "agent-resource-1",
                 gateway_id: "gateway-resource-1",
                 credential_custody_mode: :user_present,
                 target_tls: %{"mode" => "verify_ca"},
                 nla: %{"required" => true},
                 redirection_policy: %{"clipboard" => "disabled"},
                 metadata: %{"private_key" => "must-not-return", "safe" => "kept"}
               },
               actor: SystemActor.system(:remote_access_desktop_target_test)
             )

    assert target.metadata == %{"private_key" => "REDACTED", "safe" => "kept"}

    conn = get(conn, ~p"/api/remote-access/desktop-targets")
    body = json_response(conn, 200)

    listed = Enum.find(body["data"], &(Map.get(&1, "id") == target.id))
    assert listed["label"] == target_name
    assert listed["device_uid"] == "windows-resource-1"
    assert listed["target_host"] == "win-resource-1.example.com"
    assert listed["route"] == %{"agent_id" => "agent-resource-1", "gateway_id" => "gateway-resource-1"}
    assert listed["metadata"] == %{"safe" => "kept"}
    refute conn.resp_body =~ "must-not-return"
  end

  test "returns 404 when RDP desktop access is disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)

    conn = get(conn, ~p"/api/remote-access/desktop-targets")
    body = json_response(conn, 404)

    assert body["error"] == "not_found"
  end

  test "requires the RDP open permission instead of SSH", %{conn: conn, user: user} do
    put_test_permissions(user, ["devices.remote_access.ssh.open"])

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_target_provider,
      fn _scope, _opts ->
        send(self(), :unexpected_desktop_target_list)
        {:ok, []}
      end
    )

    conn = get(conn, ~p"/api/remote-access/desktop-targets")
    body = json_response(conn, 403)

    assert body["error"] == "forbidden"
    refute_receive :unexpected_desktop_target_list
  end

  describe "admin target management" do
    test "creates and lists registered targets without exposing plaintext credential material", %{conn: conn, user: user} do
      put_test_permissions(user, ["settings.edge.manage"])

      target_name = "Admin Desktop #{System.unique_integer([:positive])}"

      conn =
        post(conn, ~p"/api/admin/remote-access/desktop-targets", %{
          "name" => target_name,
          "description" => "Finance workstation",
          "enabled" => "false",
          "device_uid" => "windows-admin-1",
          "target_host" => "win-admin-1.example.com",
          "target_port" => "3389",
          "agent_id" => "agent-admin-1",
          "gateway_id" => "gateway-admin-1",
          "credential_custody_mode" => "user_present",
          "allowed_principals" => [" CARVER\\alice ", ""],
          "target_tls" => %{"mode" => "verify_ca", "password" => "must-not-return"},
          "nla" => %{"required" => true},
          "screen_policy" => %{"max_width" => 1920, "max_height" => 1080},
          "redirection_policy" => %{"clipboard" => "disabled"},
          "recording_policy" => %{"mode" => "metadata_only"},
          "metadata" => %{"private_key" => "must-not-return", "safe" => "kept"}
        })

      body = json_response(conn, 201)
      target = body["data"]

      assert target["name"] == target_name
      assert target["enabled"] == false
      assert target["device_uid"] == "windows-admin-1"
      assert target["target_host"] == "win-admin-1.example.com"
      assert target["target_port"] == 3389
      assert target["allowed_principals"] == ["CARVER\\alice"]
      assert target["target_tls"] == %{"mode" => "verify_ca", "password" => "REDACTED"}
      assert target["metadata"] == %{"private_key" => "REDACTED", "safe" => "kept"}
      refute conn.resp_body =~ "must-not-return"

      conn = get(recycle(conn), ~p"/api/admin/remote-access/desktop-targets")
      body = json_response(conn, 200)

      assert Enum.any?(body["data"], &(Map.get(&1, "id") == target["id"]))
    end

    test "updates and disables registered targets", %{conn: conn, user: user} do
      put_test_permissions(user, ["settings.edge.manage"])
      target_name = "Patch Desktop #{System.unique_integer([:positive])}"

      assert {:ok, target} =
               RemoteAccessDesktopTarget.create_target(
                 %{
                   name: target_name,
                   device_uid: "windows-patch-1",
                   target_host: "win-patch-1.example.com",
                   target_port: 3389,
                   credential_custody_mode: :user_present
                 },
                 actor: SystemActor.system(:remote_access_desktop_target_admin_test)
               )

      conn =
        patch(conn, ~p"/api/admin/remote-access/desktop-targets/#{target.id}", %{
          "description" => "Updated desktop target",
          "target_port" => 3390,
          "redirection_policy" => %{"clipboard" => "local_to_remote"},
          "approval_required" => true
        })

      body = json_response(conn, 200)
      assert body["data"]["description"] == "Updated desktop target"
      assert body["data"]["target_port"] == 3390
      assert body["data"]["approval_required"] == true
      assert body["data"]["redirection_policy"] == %{"clipboard" => "local_to_remote"}

      conn = post(recycle(conn), ~p"/api/admin/remote-access/desktop-targets/#{target.id}/disable")
      body = json_response(conn, 200)
      assert body["data"]["enabled"] == false
    end

    test "rejects authenticated users without settings.edge.manage", %{conn: _conn} do
      viewer = viewer_user_fixture()
      put_test_permissions(viewer, ["devices.remote_access.rdp.open"])
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/remote-access/desktop-targets")

      assert conn.status == 403
    end

    test "rejects invalid admin target parameters", %{conn: conn, user: user} do
      put_test_permissions(user, ["settings.edge.manage"])

      conn =
        post(conn, ~p"/api/admin/remote-access/desktop-targets", %{
          "name" => "Bad Port",
          "device_uid" => "windows-bad-port",
          "target_host" => "win-bad-port.example.com",
          "target_port" => 70_000
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
      assert body["message"] =~ "target_port"
    end
  end

  defp put_test_permissions(user, permissions) do
    Process.put({:rbac_permissions, user.id}, MapSet.new(permissions))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
