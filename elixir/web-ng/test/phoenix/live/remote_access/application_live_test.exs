defmodule ServiceRadarWebNGWeb.RemoteAccessApplicationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadar.Edge.RemoteAccessTcpTarget
  alias ServiceRadarWebNG.Accounts.Scope

  setup %{conn: conn} do
    previous_app_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled)
    previous_tcp_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_tcp_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_app_enabled, previous_app_enabled)
      restore_env(:remote_access_tcp_enabled, previous_tcp_enabled)
    end)

    user = admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      scope: Scope.for_user(user)
    }
  end

  test "renders authenticated application access launcher", %{conn: conn} do
    target_id = Ecto.UUID.generate()

    {:ok, _view, html} = live(conn, ~p"/remote-access/applications/#{target_id}")

    assert html =~ "Application remote access"
    assert html =~ target_id
    assert html =~ "RemoteAccessApplication"
  end

  test "renders TCP text launcher only for targets with browser workflow metadata", %{conn: conn, scope: scope} do
    {:ok, target} =
      RemoteAccessTcpTarget.create_target(
        %{
          name: "Echo TCP",
          device_uid: "tcp-device-1",
          agent_id: "agent-1",
          upstream_host: "127.0.0.1",
          upstream_port: 7,
          protocol_name: "echo",
          metadata: %{
            "browser_renderer" => "text",
            "client_workflow" => "Send one text line and read the response."
          }
        },
        scope: scope
      )

    {:ok, _view, html} = live(conn, ~p"/remote-access/tcp-targets/#{target.id}")

    assert html =~ "Echo TCP"
    assert html =~ "Send one text line"
    assert html =~ "RemoteAccessTCPText"
  end

  test "blocks TCP launcher when target does not declare a browser workflow", %{conn: conn, scope: scope} do
    {:ok, target} =
      RemoteAccessTcpTarget.create_target(
        %{
          name: "Opaque TCP",
          device_uid: "tcp-device-2",
          agent_id: "agent-1",
          upstream_host: "127.0.0.1",
          upstream_port: 9000,
          protocol_name: "opaque"
        },
        scope: scope
      )

    {:ok, _view, html} = live(conn, ~p"/remote-access/tcp-targets/#{target.id}")

    assert html =~ "does not declare an approved browser workflow"
    refute html =~ "RemoteAccessTCPText"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
