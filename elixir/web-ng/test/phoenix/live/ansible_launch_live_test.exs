defmodule ServiceRadarWebNGWeb.AnsibleLaunchLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user
    }
  end

  test "renders selected inventory devices without ansible-specific fields", %{conn: conn} do
    uid = "ansible-launch-device-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "camera-01",
        ip: "10.0.110.117",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/ansible/launch?devices=#{uid}")

    assert html =~ "camera-01"
    assert html =~ "Ansible-managed"
    assert html =~ "badge badge-error"
    assert html =~ "No launchable playbooks"
  end
end
