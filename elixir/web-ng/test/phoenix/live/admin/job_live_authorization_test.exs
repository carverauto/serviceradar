defmodule ServiceRadarWebNGWeb.Admin.JobLiveAuthorizationTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, operator_user_fixture: 0]

  describe "/admin/jobs authorization" do
    test "redirects operators without settings.jobs.manage", %{conn: conn} do
      user = operator_user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/analytics"} = info}} = live(conn, ~p"/admin/jobs")
      assert is_map(info.flash)
    end

    test "allows admins with settings.jobs.manage", %{conn: conn} do
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/admin/jobs")
      assert html =~ "Job Scheduler"
    end
  end
end
