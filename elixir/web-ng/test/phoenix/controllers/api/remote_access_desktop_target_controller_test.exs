defmodule ServiceRadarWebNGWeb.Api.RemoteAccessDesktopTargetControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0]

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

  defp put_test_permissions(user, permissions) do
    Process.put({:rbac_permissions, user.id}, MapSet.new(permissions))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
